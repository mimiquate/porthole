defmodule Porthole.Collector do
  @moduledoc """
  Collects tables on one or many nodes.

  Observed nodes need no Porthole code. For each table, its
  `Porthole.Gather` function reads the raw data on the node: by evaluation
  on other nodes (`Porthole.Remote`), or by a direct call on this one. The
  raw data is then shaped into rows here, where the query runs.

  Every collection runs in a separate, low-priority process with a deadline
  enforced *on the observed node* (`Porthole.Gather.with_deadline/3`):
  `:erpc` does not stop remote work when the caller times out, so without
  this a slow collection on an overloaded node would keep running after the
  query gave up. Low priority means that under load the application wins and
  Porthole waits (or gives up), never the other way around.

  With a sampling window, tables with delta columns are read twice, the
  window apart, on all nodes in parallel; the deltas are computed here.

  Nodes answer in parallel and are shaped one at a time, as they arrive
  (`reduce/7`), so the querying node holds one node's rows at a time rather
  than every node's.
  """

  alias Porthole.{Gather, Remote, Table}

  @typedoc """
  Rows per table, with whether `max_rows` cut the collection short.
  """
  @type tables :: %{String.t() => {[Table.row()], truncated :: false | :rows}}

  @typedoc "Per-table, per-node collection limits."
  @type limits :: %{
          required(:max_rows) => pos_integer(),
          optional(:all_supervisors) => boolean()
        }

  # How long a supervisor may take to answer which_children.
  @call_timeout 1_000

  @doc """
  Collects the named tables on every node, concurrently. Failing nodes are
  returned as `{node, reason}` errors and never fail the others.
  """
  @spec collect([node()], [String.t()], non_neg_integer() | nil, limits(), timeout()) ::
          {%{node() => tables()}, [{node(), String.t()}]}
  def collect(nodes, names, window_ms, limits, timeout) do
    reduce(nodes, names, window_ms, limits, timeout, %{}, fn node, table, rows, truncated, acc ->
      Map.update(
        acc,
        node,
        %{table.name() => {rows, truncated}},
        &Map.put(&1, table.name(), {rows, truncated})
      )
    end)
  end

  @doc """
  Like `collect/5`, but hands each node's rows to `fun` (one table at a
  time) as soon as that node answers, instead of returning them all: what
  the caller does not keep can be freed before the next node is shaped.
  `fun.(node, table, rows, truncated, acc)` returns the new `acc`.
  """
  @spec reduce(
          [node()],
          [String.t()],
          non_neg_integer() | nil,
          limits(),
          timeout(),
          acc,
          (node(), module(), [Table.row()], false | :rows, acc -> acc)
        ) :: {acc, [{node(), String.t()}]}
        when acc: term()
  def reduce(nodes, names, window_ms, limits, timeout, acc, fun) do
    tables = for name <- names, do: elem(Table.fetch(name), 1)
    gather_node = &gather_node(&1, tables, window_ms, limits, timeout)

    # Other nodes in tasks, which return the raw data (its most compact
    # form); this node in the calling process, so the process running the
    # query is among the collecting processes it leaves out.
    {local, remote} = Enum.split_with(nodes, &(&1 == node()))

    tasks =
      Map.new(remote, fn node ->
        task = Task.async(fn -> gather_node.(node) end)
        {task.ref, {node, task.pid}}
      end)

    {acc, errors} =
      Enum.reduce(local, {acc, []}, &handle(&1, gather_node.(&1), tables, &2, fun, timeout))

    # The node enforces each deadline itself; this is only a backstop.
    deadline = System.monotonic_time(:millisecond) + 2 * timeout + (window_ms || 0) + 2_000
    await(tasks, deadline, tables, {acc, errors}, fun, timeout)
  end

  # Handles node results in the order they arrive.
  defp await(tasks, _deadline, _tables, result, _fun, _timeout) when tasks == %{}, do: result

  defp await(tasks, deadline, tables, result, fun, timeout) do
    remaining = max(deadline - System.monotonic_time(:millisecond), 0)

    receive do
      {ref, node_result} when is_map_key(tasks, ref) ->
        Process.demonitor(ref, [:flush])
        {{node, _pid}, tasks} = Map.pop(tasks, ref)
        result = handle(node, node_result, tables, result, fun, timeout)
        await(tasks, deadline, tables, result, fun, timeout)

      {:DOWN, ref, :process, _pid, reason} when is_map_key(tasks, ref) ->
        {{node, _pid}, tasks} = Map.pop(tasks, ref)
        result = handle(node, {:error, reason}, tables, result, fun, timeout)
        await(tasks, deadline, tables, result, fun, timeout)
    after
      remaining ->
        Enum.reduce(tasks, result, fn {ref, {node, pid}}, result ->
          Process.unlink(pid)
          Process.exit(pid, :kill)
          Process.demonitor(ref, [:flush])
          handle(node, {:error, :caller_timeout}, tables, result, fun, timeout)
        end)
    end
  end

  defp handle(node, {:ok, {before, now}}, tables, {acc, errors}, fun, _timeout) do
    acc =
      Enum.reduce(tables, acc, fn table, acc ->
        {rows, truncated} = table.shape(decode(now[table]))

        rows =
          if Map.has_key?(before, table),
            do: Table.add_deltas(table, elem(table.shape(decode(before[table])), 0), rows),
            else: rows

        acc = fun.(node, table, rows, if(truncated, do: :rows, else: false), acc)
        # Give back the heap this table's rows grew, before the next one.
        :erlang.garbage_collect()
        acc
      end)

    {acc, errors}
  end

  defp handle(node, {:error, reason}, _tables, {acc, errors}, _fun, timeout),
    do: {acc, errors ++ [{node, describe(reason, timeout)}]}

  # Remote results arrive encoded (see gather/4).
  defp decode(raw) when is_binary(raw), do: :erlang.binary_to_term(raw)
  defp decode(raw), do: raw

  # Reads the tables on `node` (twice for sampled tables, the window apart)
  # and returns the raw data, unshaped.
  defp gather_node(node, tables, window_ms, limits, timeout) do
    sampled = if window_ms, do: Enum.filter(tables, &(&1.deltas() != [])), else: []

    with {:ok, before} <- snapshot(node, sampled, limits, timeout),
         :ok <- if(sampled != [], do: Process.sleep(window_ms), else: :ok),
         {:ok, now} <- snapshot(node, tables, limits, timeout) do
      {:ok, {before, now}}
    end
  end

  # Reads each table on `node` once, raw.
  defp snapshot(node, tables, limits, timeout) do
    gather_limits = %{
      max_rows: limits.max_rows,
      call_timeout: @call_timeout,
      all_supervisors: Map.get(limits, :all_supervisors, false)
    }

    Enum.reduce_while(tables, {:ok, %{}}, fn table, {:ok, acc} ->
      {name, args} = table.gather(gather_limits)

      case gather(node, name, args, timeout) do
        {:ok, raw} -> {:cont, {:ok, Map.put(acc, table, raw)}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp gather(node, name, args, budget) do
    if node == node() do
      Gather.with_deadline(Function.capture(Gather, name, length(args) + 1), args, budget)
    else
      # Kept encoded until it is shaped: tasks hand it over without copying.
      Remote.run_encoded(node, name, args, budget)
    end
  end

  defp describe(:timeout, timeout),
    do:
      "collection took longer than #{timeout}ms and was stopped on this node; " <>
        "the node may be overloaded, retry later or with a shorter window"

  defp describe(:caller_timeout, _timeout), do: "collection timed out"

  defp describe({:old_otp, release}, _),
    do: "Porthole needs OTP 27+, this node runs OTP #{release}"

  defp describe(:no_elixir, _),
    do: "this node does not run Elixir (Porthole observes Elixir applications)"

  # Erlang gives no reason for a failed connection; these are the usual ones.
  defp describe({:error, {:erpc, :noconnection}}, _),
    do:
      "node is not reachable: it may be down, the network may block it (epmd on 4369, or " <>
        "its distribution port), or its cookie differs from this node's"

  defp describe({:error, {:erpc, :timeout}}, _), do: "collection timed out"

  defp describe(other, _), do: "collection failed: " <> Porthole.Term.render(other)
end

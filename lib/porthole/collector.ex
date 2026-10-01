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
  """

  alias Porthole.{Gather, Remote, Table}

  @typedoc """
  Rows per table, with which limit (if any) cut the collection short.
  """
  @type tables :: %{String.t() => {[Table.row()], truncated :: false | :rows | :bytes}}

  @typedoc "Per-table, per-node collection limits."
  @type limits :: %{max_rows: pos_integer(), max_bytes: pos_integer()}

  # How long a supervisor may take to answer which_children.
  @call_timeout 1_000

  @doc """
  Collects the named tables on every node, concurrently. Failing nodes are
  returned as `{node, reason}` errors and never fail the others.
  """
  @spec collect([node()], [String.t()], non_neg_integer() | nil, limits(), timeout()) ::
          {%{node() => tables()}, [{node(), String.t()}]}
  def collect(nodes, names, window_ms, limits, timeout) do
    tables = for name <- names, do: elem(Table.fetch(name), 1)
    collect_node = &collect_node(&1, tables, window_ms, limits, timeout)

    # Other nodes in tasks; this node in the calling process, so the process
    # running the query is among the collecting processes it leaves out.
    {local, remote} = Enum.split_with(nodes, &(&1 == node()))
    tasks = for node <- remote, do: {node, Task.async(fn -> collect_node.(node) end)}
    local_results = for node <- local, do: {node, collect_node.(node)}

    remote_results =
      for {node, task} <- tasks do
        # The node enforces each deadline itself; this is only a backstop.
        case Task.yield(task, 2 * timeout + (window_ms || 0) + 2_000) ||
               Task.shutdown(task, :brutal_kill) do
          {:ok, result} -> {node, result}
          _ -> {node, {:error, :caller_timeout}}
        end
      end

    Enum.reduce(local_results ++ remote_results, {%{}, []}, fn
      {node, {:ok, tables}}, {ok, errors} ->
        {Map.put(ok, node, tables), errors}

      {node, {:error, reason}}, {ok, errors} ->
        {ok, errors ++ [{node, describe(reason, timeout)}]}
    end)
  end

  defp collect_node(node, tables, window_ms, limits, timeout) do
    sampled = if window_ms, do: Enum.filter(tables, &(&1.deltas() != [])), else: []

    with {:ok, before} <- snapshot(node, sampled, limits, timeout),
         :ok <- if(sampled != [], do: Process.sleep(window_ms), else: :ok),
         {:ok, now} <- snapshot(node, tables, limits, timeout) do
      {:ok,
       Map.new(tables, fn table ->
         {rows, truncated} = now[table]

         rows =
           if Map.has_key?(before, table),
             do: Table.add_deltas(table, elem(before[table], 0), rows),
             else: rows

         {table.name(), cap_bytes(rows, if(truncated, do: :rows, else: false), limits.max_bytes)}
       end)}
    end
  end

  # Reads each table on `node` once, and shapes it here.
  defp snapshot(node, tables, limits, timeout) do
    gather_limits = %{max_rows: limits.max_rows, call_timeout: @call_timeout}

    Enum.reduce_while(tables, {:ok, %{}}, fn table, {:ok, acc} ->
      {name, args} = table.gather(gather_limits)

      case gather(node, name, args, timeout) do
        {:ok, raw} -> {:cont, {:ok, Map.put(acc, table, table.shape(raw))}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp gather(node, name, args, budget) do
    if node == node() do
      Gather.with_deadline(Function.capture(Gather, name, length(args) + 1), args, budget)
    else
      Remote.run(node, name, args, budget)
    end
  end

  # Rows are bounded in width, but many rows can still add up. This bounds what
  # the querying node loads.
  defp cap_bytes(rows, truncated, max_bytes) do
    rows
    |> Enum.reduce_while({[], 0}, fn row, {kept, size} ->
      size = size + :erlang.external_size(row)
      if size > max_bytes, do: {:halt, {:cut, kept}}, else: {:cont, {[row | kept], size}}
    end)
    |> case do
      {:cut, kept} -> {Enum.reverse(kept), :bytes}
      {_kept, _size} -> {rows, truncated}
    end
  end

  defp describe(:timeout, timeout),
    do:
      "collection took longer than #{timeout}ms and was stopped on this node; " <>
        "the node may be overloaded, retry later or with a shorter window"

  defp describe(:caller_timeout, _timeout), do: "collection timed out"

  defp describe({:old_otp, release}, _),
    do: "Porthole needs OTP 27+, this node runs OTP #{release}"

  defp describe({:undef, [{Enum, _fun, _args, _location} | _]}, _),
    do: "this node does not run Elixir (Porthole observes Elixir applications)"

  defp describe({:error, {:erpc, :noconnection}}, _), do: "node is not reachable"
  defp describe({:error, {:erpc, :timeout}}, _), do: "collection timed out"

  defp describe(other, _), do: "collection failed: " <> Porthole.Term.render(other)
end

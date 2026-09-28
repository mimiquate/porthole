defmodule Porthole.Collector do
  @moduledoc """
  Collects tables on one or many nodes. Pure Elixir, no NIFs: this is what
  observed nodes run, through `:erpc.multicall/5`.

  On each node the work runs in a separate, low-priority process with a
  deadline enforced *on that node*: `:erpc` does not stop remote work when
  the caller times out, so without this a slow collection on an overloaded
  node would keep running after the query gave up, and every retry would add
  another one. Low priority means that under load the application wins and
  Porthole waits (or gives up), never the other way around.
  """

  alias Porthole.Table

  @type tables :: %{String.t() => {[Table.row()], truncated :: boolean()}}

  @doc """
  Collects the named tables on every node, concurrently. Failing nodes are
  returned as `{node, reason}` errors and never fail the others.
  """
  @spec collect([node()], [String.t()], non_neg_integer() | nil, pos_integer(), timeout()) ::
          {%{node() => tables()}, [{node(), String.t()}]}
  def collect(nodes, names, window_ms, max_rows, timeout) do
    args = [names, window_ms, max_rows, timeout]
    # Slightly longer than the on-node deadline, so nodes report their own
    # (more precise) timeout before the caller gives up on them.
    call_timeout = timeout + (window_ms || 0) + 1_000

    results =
      if nodes == [node()],
        do: [local(args)],
        else: :erpc.multicall(nodes, __MODULE__, :collect_local, args, call_timeout)

    Enum.zip(nodes, results)
    |> Enum.reduce({%{}, []}, fn
      {node, {:ok, tables}}, {ok, errors} -> {Map.put(ok, node, tables), errors}
      {node, error}, {ok, errors} -> {ok, errors ++ [{node, describe(error)}]}
    end)
  end

  @doc """
  Collects the named tables on this node. With a window, tables with delta
  columns are also snapshotted at the start of the window.
  """
  @spec collect_local([String.t()], non_neg_integer() | nil, pos_integer(), timeout()) :: tables()
  def collect_local(names, window_ms, max_rows, timeout) do
    check_otp!()
    caller = self()
    budget = timeout + (window_ms || 0)

    {worker, ref} =
      spawn_monitor(fn ->
        Process.flag(:priority, :low)
        # Tables leave out the collecting process and its callers.
        Process.put(:"$callers", [caller])
        send(caller, {:collected, self(), collect_tables(names, window_ms, max_rows)})
      end)

    receive do
      {:collected, ^worker, tables} ->
        Process.demonitor(ref, [:flush])
        tables

      {:DOWN, ^ref, :process, ^worker, reason} ->
        exit(reason)
    after
      budget ->
        Process.exit(worker, :kill)
        Process.demonitor(ref, [:flush])

        raise "collection took longer than #{budget}ms and was stopped on this node; " <>
                "the node may be overloaded, retry later or with a shorter window"
    end
  end

  defp collect_tables(names, window_ms, max_rows) do
    tables = for name <- names, do: elem(Table.fetch(name), 1)
    sampled = if window_ms, do: Enum.filter(tables, &(&1.deltas() != [])), else: []

    before = Map.new(sampled, fn table -> {table, elem(table.collect(max_rows), 0)} end)
    if sampled != [], do: Process.sleep(window_ms)

    Map.new(tables, fn table ->
      {rows, truncated} = table.collect(max_rows)

      rows =
        if Map.has_key?(before, table),
          do: Table.add_deltas(table, before[table], rows),
          else: rows

      {table.name(), {rows, truncated}}
    end)
  end

  # Local failures are reported like remote ones instead of failing the query.
  defp local(args) do
    {:ok, apply(__MODULE__, :collect_local, args)}
  rescue
    exception -> {:error, {:exception, exception, __STACKTRACE__}}
  end

  # Collectors read single process dictionary keys with Process.info/2, which
  # older releases reject. Checked per query (never at boot) so an old node
  # reports an error instead of crashing its host application.
  @min_otp 27

  defp check_otp! do
    release = :erlang.system_info(:otp_release) |> List.to_integer()

    if release < @min_otp,
      do: raise("Porthole needs OTP #{@min_otp}+, this node runs OTP #{release}")
  end

  defp describe({:error, {:erpc, :noconnection}}), do: "node is not reachable"
  defp describe({:error, {:erpc, :timeout}}), do: "collection timed out"

  defp describe({:error, {:exception, :undef, [{__MODULE__, _, _, _} | _]}}),
    do: "Porthole is not loaded on this node"

  defp describe({:error, {:exception, exception, _stack}}) when is_exception(exception),
    do: "collection failed: " <> Porthole.Term.truncate(Exception.message(exception), 500)

  defp describe(other), do: "collection failed: " <> Porthole.Term.render(other)
end

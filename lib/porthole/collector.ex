defmodule Porthole.Collector do
  @moduledoc """
  Collects tables on one or many nodes. Pure Elixir, no NIFs: this is what
  observed nodes run, through `:erpc.multicall/5`.
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
    args = [names, window_ms, max_rows]

    results =
      if nodes == [node()],
        do: [{:ok, apply(__MODULE__, :collect_local, args)}],
        else: :erpc.multicall(nodes, __MODULE__, :collect_local, args, timeout + (window_ms || 0))

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
  @spec collect_local([String.t()], non_neg_integer() | nil, pos_integer()) :: tables()
  def collect_local(names, window_ms, max_rows) do
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

  defp describe({:error, {:erpc, :noconnection}}), do: "node is not reachable"
  defp describe({:error, {:erpc, :timeout}}), do: "collection timed out"

  defp describe({:error, {:exception, :undef, [{__MODULE__, _, _, _} | _]}}),
    do: "Porthole is not loaded on this node"

  defp describe(other), do: "collection failed: " <> Porthole.Term.render(other)
end

defmodule Porthole.Table do
  @moduledoc """
  The behaviour every table implements, and the table registry.

  A table is two halves: a `Porthole.Gather` function that reads raw data on
  the observed node (`c:gather/1` names it), and `c:shape/1`, which turns
  that data into rows (maps of text, integers and booleans) on the querying
  node. Observed nodes never need Porthole: the gather function's code is
  evaluated there (see `Porthole.Remote`).

  When a query samples over a window, every column listed in `c:deltas/0`
  gets a `<column>_delta` companion: its change between the start and the end
  of the window, matched on `c:key/0`. Rows that did not exist at the start
  get `nil`.

  A collection is **not an atomic snapshot**: processes spawn, exit and change
  while a table is walked.
  """

  @type column :: {atom(), :text | :integer | :boolean, String.t()}
  @type row :: %{atom() => String.t() | integer() | boolean() | nil}

  @typedoc "Collection limits for one table on one node."
  @type limits :: %{max_rows: pos_integer(), call_timeout: timeout()}

  @callback name() :: String.t()
  @callback description() :: String.t()
  @callback columns() :: [column()]
  @doc "The column identifying a row across snapshots."
  @callback key() :: atom()
  @doc "Integer columns that get a `_delta` column when sampling."
  @callback deltas() :: [atom()]
  @doc """
  The `Porthole.Gather` function that reads this table's raw data on a node,
  and its arguments (after the caller's pid), within `limits`.
  """
  @callback gather(limits()) :: {atom(), list()}

  @doc """
  Turns raw data from the gather function into rows; the flag tells whether
  rows were left out. Runs on the querying node.
  """
  @callback shape(raw :: term()) :: {[row()], truncated :: boolean()}

  @tables [
    Porthole.Tables.Processes,
    Porthole.Tables.Supervisors,
    Porthole.Tables.EtsTables,
    Porthole.Tables.Ports,
    Porthole.Tables.Applications,
    Porthole.Tables.System
  ]

  @doc "All table modules."
  @spec all() :: [module()]
  def all, do: @tables

  @doc "Finds a table module by name."
  @spec fetch(String.t()) :: {:ok, module()} | :error
  def fetch(name) do
    case Enum.find(@tables, &(&1.name() == name)) do
      nil -> :error
      table -> {:ok, table}
    end
  end

  @doc "Columns of `table`, including `_delta` columns when `sampled?`."
  @spec columns(module(), boolean()) :: [column()]
  def columns(table, sampled?) do
    deltas =
      if sampled?,
        do: for(c <- table.deltas(), do: {delta(c), :integer, "Change in #{c} over the window."}),
        else: []

    table.columns() ++ deltas
  end

  @doc "Adds `_delta` columns to `rows`, comparing them with `before`."
  @spec add_deltas(module(), [row()], [row()]) :: [row()]
  def add_deltas(table, before, rows) do
    key = table.key()
    before = Map.new(before, &{&1[key], &1})

    Enum.map(rows, fn row ->
      previous = before[row[key]]

      Enum.reduce(table.deltas(), row, fn column, row ->
        Map.put(row, delta(column), previous && row[column] - previous[column])
      end)
    end)
  end

  defp delta(column), do: :"#{column}_delta"

  @doc """
  Collects `table` on this node, by calling its gather function directly.
  """
  @spec collect(module(), limits()) :: {[row()], boolean()}
  def collect(table, limits) do
    {name, args} = table.gather(limits)
    table.shape(apply(Porthole.Gather, name, [self() | args]))
  end
end

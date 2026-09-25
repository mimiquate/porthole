defmodule Porthole.Table do
  @moduledoc """
  The behaviour every table implements, and the table registry.

  A table is a pure-Elixir function that walks the local node and returns
  rows (maps of text, integers and booleans). Tables never touch SQLite, so
  observed nodes need nothing but these modules.

  When a query samples over a window, every column listed in `c:deltas/0`
  gets a `<column>_delta` companion: its change between the start and the end
  of the window, matched on `c:key/0`. Rows that did not exist at the start
  get `nil`.

  A collection is **not an atomic snapshot**: processes spawn, exit and change
  while a table is walked.
  """

  @type column :: {atom(), :text | :integer | :boolean, String.t()}
  @type row :: %{atom() => String.t() | integer() | boolean() | nil}

  @callback name() :: String.t()
  @callback description() :: String.t()
  @callback columns() :: [column()]
  @doc "The column identifying a row across snapshots."
  @callback key() :: atom()
  @doc "Integer columns that get a `_delta` column when sampling."
  @callback deltas() :: [atom()]
  @doc "Collects at most `max_rows` rows; the flag tells if rows were left out."
  @callback collect(max_rows :: pos_integer()) :: {[row()], truncated :: boolean()}

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

  @doc false
  # Takes at most `max` elements, telling whether any were left out.
  @spec take([term()], pos_integer()) :: {[term()], boolean()}
  def take(list, max) do
    {taken, rest} = Enum.split(list, max)
    {taken, rest != []}
  end
end

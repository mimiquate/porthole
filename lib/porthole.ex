defmodule Porthole do
  @moduledoc """
  Read-only SQL over a live BEAM system, built for coding agents.

      iex> {:ok, result} = Porthole.query("SELECT running FROM applications WHERE name = 'porthole'")
      iex> result.rows
      [[1]]

  Tables: `processes`, `supervisors`, `ets_tables`, `applications`; see
  `schema/0`. Every table has a `node` column. Pass `window_ms:` to sample
  and get `_delta` columns (e.g. `reductions_delta`).

  Entry points: `query/2` from Elixir, `print/2` from a remote shell,
  `mix porthole.query` and `mix porthole.mcp`.
  """

  alias Porthole.{Error, Query, Result, Table}

  @doc "Runs a read-only SQL query. See `Porthole.Query.run/2` for options."
  @spec query(String.t(), keyword()) :: {:ok, Result.t()} | {:error, Error.t()}
  defdelegate query(sql, opts \\ []), to: Query, as: :run

  @doc "Like `query/2`, raising on errors."
  @spec query!(String.t(), keyword()) :: Result.t()
  def query!(sql, opts \\ []) do
    case query(sql, opts) do
      {:ok, result} -> result
      {:error, error} -> raise error
    end
  end

  @doc "Runs a query and prints a text table. Meant for remote shells and IEx."
  @spec print(String.t(), keyword()) :: :ok
  def print(sql, opts \\ []), do: sql |> query(opts) |> format() |> IO.puts()

  @doc """
  Collects one table on this node, without SQL. This needs no NIF.

      iex> {:ok, {rows, false}} = Porthole.collect("applications")
      iex> Enum.find(rows, &(&1.name == "porthole")).running
      true

  """
  @spec collect(String.t(), pos_integer()) :: {:ok, {[Table.row()], boolean()}} | :error
  def collect(table, max_rows \\ 50_000) do
    with {:ok, table} <- Table.fetch(table),
         do: {:ok, Table.collect(table, %{max_rows: max_rows, call_timeout: 1_000})}
  end

  @doc "Tables and their columns, with documentation."
  @spec schema() :: [map()]
  def schema do
    for table <- Table.all() do
      %{
        name: table.name(),
        description: table.description(),
        columns:
          for({name, type, doc} <- table.columns(), do: %{name: name, type: type, doc: doc}),
        sampled: for(column <- table.deltas(), do: :"#{column}_delta")
      }
    end
  end

  @doc "Formats a query outcome as a text table."
  @spec format({:ok, Result.t()} | {:error, Error.t()}) :: String.t()
  def format({:error, error}), do: "error (#{error.reason}): #{error.message}"

  def format({:ok, %Result{} = result}) do
    cells = for row <- result.rows, do: Enum.map(row, &cell/1)

    widths =
      Enum.zip_with([result.columns | cells], fn col ->
        col |> Enum.map(&String.length/1) |> Enum.max()
      end)

    line =
      &(&1
        |> Enum.zip(widths)
        |> Enum.map_join(" | ", fn {v, w} -> String.pad_trailing(v, w) end))

    footer =
      ["(#{length(result.rows)} rows)"] ++
        Enum.map(result.notes, &"TRUNCATED: #{&1}") ++
        Enum.map(result.errors, &"ERROR on #{&1.node}: #{&1.message}")

    Enum.join(
      [line.(result.columns), Enum.map_join(widths, "-+-", &String.duplicate("-", &1))] ++
        Enum.map(cells, line) ++ footer,
      "\n"
    )
  end

  defp cell(nil), do: "NULL"

  defp cell(value) when is_binary(value),
    do: if(String.length(value) > 60, do: String.slice(value, 0, 59) <> "…", else: value)

  defp cell(value), do: to_string(value)
end

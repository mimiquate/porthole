defmodule Porthole.Result do
  @moduledoc """
  A query result.

    * `columns`, `rows` - the result set, rows as lists in column order.
    * `truncated` - `true` when anything was cut. `notes` says what, e.g.
      rows beyond the cap, shortened cells, or a table whose collection hit
      the row cap on some node (counts and sums are then incomplete).
    * `errors` - nodes that could not be collected; their rows are missing.
    * `nodes` - nodes queried; `window_ms` - sampling window, if any.
  """

  @type t :: %__MODULE__{
          columns: [String.t()],
          rows: [[term()]],
          truncated: boolean(),
          notes: [String.t()],
          errors: [%{node: String.t(), message: String.t()}],
          nodes: [String.t()],
          window_ms: pos_integer() | nil
        }

  @derive JSON.Encoder
  defstruct columns: [],
            rows: [],
            truncated: false,
            notes: [],
            errors: [],
            nodes: [],
            window_ms: nil

  @doc "Rows as maps keyed by column name."
  @spec maps(t()) :: [map()]
  def maps(%__MODULE__{columns: columns, rows: rows}),
    do: Enum.map(rows, &(columns |> Enum.zip(&1) |> Map.new()))
end

defmodule Porthole.Tables.EtsTables do
  @moduledoc """
  One row per ETS table, including private ones. Only metadata is read, never
  table contents. Join `owner` with `processes.pid`.
  """

  @behaviour Porthole.Table

  alias Porthole.{Remote, Term}

  @impl true
  def name, do: "ets_tables"

  @impl true
  def description, do: "One row per ETS table: owner, type, access, size, memory."

  @impl true
  def key, do: :id

  @impl true
  def deltas, do: [:size, :memory]

  @impl true
  def columns do
    [
      {:id, :text, "Name for named tables, otherwise #Reference<...>."},
      {:name, :text, "Table name."},
      {:owner, :text, "Owner pid (join with processes.pid)."},
      {:type, :text, "set | ordered_set | bag | duplicate_bag"},
      {:protection, :text, "public | protected | private"},
      {:size, :integer, "Number of objects."},
      {:memory, :integer, "Bytes."}
    ]
  end

  @impl true
  def gather(limits), do: {:ets_tables, [limits.max_rows]}

  @impl true
  def shape(%{rows: rows, truncated: truncated, word_size: word_size}) do
    rows =
      for {table, info} <- rows do
        %{
          id: if(is_atom(table), do: Term.name(table), else: Remote.pid(table)),
          name: Term.name(info[:name]),
          owner: Remote.pid(info[:owner]),
          type: Atom.to_string(info[:type]),
          protection: Atom.to_string(info[:protection]),
          size: info[:size],
          memory: info[:memory] * word_size
        }
      end

    {rows, truncated}
  end
end

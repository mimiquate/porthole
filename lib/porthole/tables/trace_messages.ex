defmodule Porthole.Tables.TraceMessages do
  @moduledoc """
  The messages sent to one process during a trace (`trace: %{messages_to:
  ...}`): who sent each and what kind of message it was. Join `sender` with
  `processes.pid`.
  """

  @behaviour Porthole.Table

  alias Porthole.{Remote, Term}

  @impl true
  def name, do: "trace_messages"

  @impl true
  def description,
    do:
      ~s(With trace {"messages_to": "<name or pid>"}: one row per message sent to that ) <>
        "process during the window. Answers who floods a mailbox. Only messages sent from " <>
        "the same node are seen."

  @impl true
  def key, do: :sender

  @impl true
  def deltas, do: []

  @impl true
  def columns do
    [
      {:sender, :text, "Pid of the sending process (join processes.pid)."},
      {:receiver, :text, "Pid of the traced process."},
      {:tag, :text,
       "Kind of message: its first element (order_event), a struct's name, or call:<tag> / " <>
         "cast:<tag> for GenServer requests; NULL if none. Nothing else of the message is kept."},
      {:at_ms, :integer, "When it was sent, in ms since the trace started."}
    ]
  end

  @impl true
  def gather(limits),
    do:
      {:trace,
       [
         limits.querier,
         limits.trace,
         limits.window_ms,
         limits.read_ms,
         limits.max_events,
         limits.max_rows
       ]}

  @impl true
  def shape(raw) do
    rows =
      for {sender, receiver, tag, at_ms} <- Map.get(raw, :rows, []) do
        %{sender: Remote.pid(sender), receiver: Remote.pid(receiver), tag: tag(tag), at_ms: at_ms}
      end

    {rows, {:trace, Map.delete(raw, :rows)}}
  end

  defp tag(nil), do: nil
  defp tag({kind, nil}), do: Atom.to_string(kind)
  defp tag({kind, tag}), do: "#{kind}:#{tag(tag)}"
  defp tag(atom) when is_atom(atom), do: Term.name(atom)
end

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
      ~s(With trace {"messages_to": "<name or pid>"}: one row per message another process ) <>
        "(or the process itself) sent to it during the window. Answers who floods a " <>
        "mailbox. Not seen, so no rows does not mean no messages: timer messages " <>
        "(Process.send_after, :timer), replies to the process's own calls (GenServer.call " <>
        "replies are sent to an alias, not the pid) and messages from other nodes."

  @impl true
  def key, do: :sender

  @impl true
  def deltas, do: []

  @impl true
  def columns do
    [
      {:sender, :text, "Pid of the sending process (join processes.pid)."},
      {:sender_name, :text,
       "Its registered name, identified on the node during the trace, so known even if it " <>
         "has exited since; NULL if none, or if it exited before it could be identified."},
      {:sender_initial_call, :text,
       "Its initial call (Mod.init/1 for a GenServer), identified the same way. Tasks " <>
         "and plain spawns show :erlang.apply/2: see sender_started_by."},
      {:sender_started_by, :text,
       "Who started it: the process a task works for (e.g. the LiveView behind a preload " <>
         "task), or else its parent; a name or an initial call. For a LiveView, its " <>
         "transport: the websocket connection's handler (Bandit, Cowboy), or " <>
         "Phoenix.Transports.LongPoll.Server when it fell back to long polling. NULL, like " <>
         "the other sender_ columns, for a sender that exited right after sending."},
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
      for {sender, receiver, tag, at_ms, identity} <- Map.get(raw, :rows, []) do
        {name, initial_call, started_by} = Porthole.Trace.identity(identity)

        %{
          sender: Remote.pid(sender),
          sender_name: name,
          sender_initial_call: initial_call,
          sender_started_by: started_by,
          receiver: Remote.pid(receiver),
          tag: tag(tag),
          at_ms: at_ms
        }
      end

    {rows, {:trace, Map.delete(raw, :rows)}}
  end

  defp tag(nil), do: nil
  defp tag({kind, nil}), do: Atom.to_string(kind)
  defp tag({kind, tag}), do: "#{kind}:#{tag(tag)}"
  defp tag(atom) when is_atom(atom), do: Term.name(atom)
end

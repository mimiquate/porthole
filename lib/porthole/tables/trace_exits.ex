defmodule Porthole.Tables.TraceExits do
  @moduledoc """
  Exits during a trace (`trace: %{exits: ...}`) of a process and of every
  process it starts: the reason's class and where it was raised, never the
  reason's data (arguments, state). Exited processes are gone, so `name` and
  `initial_call` say who each was: identified on the node when the trace
  started or when the process was spawned.
  """

  @behaviour Porthole.Table

  alias Porthole.{Remote, Term}

  @impl true
  def name, do: "trace_exits"

  @impl true
  def description,
    do:
      ~s(With trace {"exits": "<name or pid>"}: one row per exit, during the window, of ) <>
        "that process or any process it started (e.g. a supervisor's children, restarts " <>
        "included). Answers why processes keep crashing."

  @impl true
  def key, do: :pid

  @impl true
  def deltas, do: []

  @impl true
  def columns do
    [
      {:pid, :text, "Pid of the process that exited (gone: it joins nothing)."},
      {:name, :text, "Its registered name, if it had one."},
      {:initial_call, :text,
       "Its initial call (Mod.init/1 for a GenServer, the function a task ran), identified " <>
         "when the trace started or when it was spawned; NULL if unknown. Tasks and plain " <>
         "spawns may show :erlang.apply/2: see started_by."},
      {:started_by, :text,
       "Who started it: the process a task works for (e.g. the LiveView behind a preload " <>
         "task), or else the process that spawned it; a name or an initial call. For a " <>
         "LiveView, its transport: the websocket connection's handler (Bandit, Cowboy), or " <>
         "Phoenix.Transports.LongPoll.Server when it fell back to long polling. (A first, " <>
         "server-rendered page load runs inside the HTTP handler: no LiveView process.)"},
      {:reason, :text,
       "Class of the exit reason: normal, shutdown, killed, an exception (FunctionClauseError, " <>
         "MatchError) or another error atom (timeout, noproc). Never the reason's data."},
      {:location, :text, "Mod.fun/arity where it was raised, when known."},
      {:at_ms, :integer, "When it exited, in ms since the window started."}
    ]
  end

  @impl true
  defdelegate gather(limits), to: Porthole.Tables.TraceMessages

  @impl true
  def shape(raw) do
    rows =
      for {pid, reason, location, at_ms, identity} <- Map.get(raw, :rows, []) do
        {name, initial_call, started_by} = Porthole.Trace.identity(identity)

        %{
          pid: Remote.pid(pid),
          name: name,
          initial_call: initial_call,
          started_by: started_by,
          reason: Porthole.Trace.exception_name(reason),
          location: Term.mfa(location),
          # Events are timed from the start of the function; the window
          # starts after setup.
          at_ms: max(at_ms - Map.get(raw, :setup_ms, 0), 0)
        }
      end

    {rows, {:trace, Map.delete(raw, :rows)}}
  end
end

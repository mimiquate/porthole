defmodule Porthole.Tables.TraceExits do
  @moduledoc """
  Exits during a trace (`trace: %{exits: ...}`) of a process and of every
  process it starts: the reason's class and where it was raised, never the
  reason's data (arguments, state). Exited processes are gone, so their pids
  join only with rows collected before (e.g. other traces); the reason and
  location usually say enough.
  """

  @behaviour Porthole.Table

  alias Porthole.{Remote, Term}

  # Errors raised by the VM, under the names Elixir developers see in logs.
  @exceptions %{
    function_clause: FunctionClauseError,
    undef: UndefinedFunctionError,
    badarg: ArgumentError,
    badarith: ArithmeticError,
    badmatch: MatchError,
    case_clause: CaseClauseError,
    try_clause: TryClauseError,
    with_clause: WithClauseError,
    badkey: KeyError,
    badmap: BadMapError,
    badfun: BadFunctionError,
    badarity: BadArityError,
    system_limit: SystemLimitError
  }

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
      {:pid, :text, "Pid of the process that exited."},
      {:reason, :text,
       "Class of the exit reason: normal, shutdown, killed, an exception (FunctionClauseError, " <>
         "MatchError) or another error atom (timeout, noproc). Never the reason's data."},
      {:location, :text, "Mod.fun/arity where it was raised, when known."},
      {:at_ms, :integer, "When it exited, in ms since the trace started."}
    ]
  end

  @impl true
  defdelegate gather(limits), to: Porthole.Tables.TraceMessages

  @impl true
  def shape(raw) do
    rows =
      for {pid, reason, location, at_ms} <- Map.get(raw, :rows, []) do
        %{
          pid: Remote.pid(pid),
          reason: Term.name(Map.get(@exceptions, reason, reason)),
          location: Term.mfa(location),
          at_ms: at_ms
        }
      end

    {rows, {:trace, Map.delete(raw, :rows)}}
  end
end

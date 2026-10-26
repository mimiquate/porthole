defmodule Porthole.Tables.TraceShapes do
  @moduledoc """
  Every call to one function during a trace (`trace: %{shapes: ...}`): the
  *shapes* of its arguments and result, its outcome and how long it took.

  A shape is a term's structure without its values: types and sizes
  (`binary(5)`, `list(20) of %{...}`), atoms (`:ok`, `:error`,
  `:invalid_format`) and map keys. **Map keys are shown as they are**, string,
  atom and integer ones alike (up to 16 per map): in a map keyed by data
  (emails, user ids, tokens), those keys reach the agent.
  A policy can disallow shapes (`trace_shapes: false`).
  """

  @behaviour Porthole.Table

  alias Porthole.{Remote, Trace}

  @impl true
  def name, do: "trace_shapes"

  @impl true
  def description,
    do:
      ~s(With trace {"shapes": "<Module.function/arity>"}: one row per call during the ) <>
        "window, with the shapes of its arguments and result (types, sizes, atoms and map " <>
        "keys, never other values), its outcome and its wall-clock duration. Answers what " <>
        "a function receives and returns now: silent {:error, ...} returns, a changed " <>
        "payload format, which input makes it fail."

  @impl true
  def key, do: :pid

  @impl true
  def deltas, do: []

  @impl true
  def columns do
    [
      {:pid, :text, "Pid of the calling process (join processes.pid)."},
      {:name, :text, "Its registered name, identified on the node during the trace."},
      {:initial_call, :text, "Its initial call (Mod.init/1 for a GenServer)."},
      {:started_by, :text, "Who started it (as in trace_messages.sender_started_by)."},
      {:args, :text,
       "Shapes of the arguments, e.g. (%{\"amount\" => binary(5)}, :eur); NULL for a call " <>
         "made before the trace started."},
      {:outcome, :text,
       "ok ({:ok, _} or :ok), error ({:error, _} or :error), returned (anything else) or " <>
         "raised."},
      {:result, :text,
       "Shape of the result, e.g. {:error, :invalid_format}; for raised, the exception " <>
         "(ArgumentError, FunctionClauseError), never its message."},
      {:duration_us, :integer,
       "Wall-clock time from call to return, in µs, waiting included (database, other " <>
         "processes): latency, unlike trace_calls.time_us. NULL if called before the trace."},
      {:at_ms, :integer, "When it returned, in ms since the window started."}
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
      for {pid, args, outcome, duration_us, at_ms, identity} <- Map.get(raw, :rows, []) do
        {name, initial_call, started_by} = Trace.identity(identity)
        {outcome, result} = Trace.outcome(outcome)

        %{
          pid: Remote.pid(pid),
          name: name,
          initial_call: initial_call,
          started_by: started_by,
          args: args && "(" <> Enum.map_join(args, ", ", &Trace.render_shape/1) <> ")",
          outcome: outcome,
          result: result,
          duration_us: duration_us,
          # Events are timed from the start of the function; the window
          # starts after setup.
          at_ms: max(at_ms - Map.get(raw, :setup_ms, 0), 0)
        }
      end

    {rows, {:trace, Map.delete(raw, :rows)}}
  end
end

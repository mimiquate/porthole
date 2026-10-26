defmodule Porthole.Trace do
  @moduledoc """
  What a query traces: the `:trace` query option (the MCP tool's `trace`
  argument). One of:

    * `%{messages_to: "Shop.Notifications"}` (a registered name or a pid):
      the messages sent to that process, in `trace_messages`;
    * `%{calls: "Shop.Pricing"}` or `%{calls: "Shop.Pricing.quote/1"}`: call
      counts and running time of a module's functions, per process, in
      `trace_calls`;
    * `%{exits: "Shop.Payments.Supervisor"}`: exits of that process and of
      every process it starts, with the reason's class, in `trace_exits`;
    * `%{shapes: "Shop.Payments.parse/1"}`: every call to that function,
      with the *shapes* of its arguments and result (their structure: types,
      sizes, atoms and map keys, never other values), its outcome and its
      duration, in `trace_shapes`. Map keys are shown as they are, so keys
      that are personal data (emails, ids) do show: shapes are off unless the
      environment policy enables them (`trace_shapes: true`).

  The trace runs during the query's window (`window_ms`, required), on every
  queried node, within the policy's `max_trace_events`, and needs the
  `:trace` tier. What is traced comes only from this option, never from the
  SQL.
  """

  alias Porthole.{Error, Tables}

  @typedoc "A process: registered names to try, or a pid as `~c\"<0.123.0>\"`."
  @type target :: {:name, [String.t()]} | {:pid, charlist()}

  @type t ::
          {:messages_to, target()}
          | {:exits, target()}
          | {:calls, {modules :: [String.t()], function :: String.t() | nil, arity() | nil}}
          | {:shapes, {modules :: [String.t()], function :: String.t(), arity()}}

  @kinds %{
    "messages_to" => :messages_to,
    "calls" => :calls,
    "exits" => :exits,
    "shapes" => :shapes
  }

  @usage ~s(trace must be one of {"messages_to": "<registered name or pid>"}, ) <>
           ~s({"calls": "<Module>" or "<Module.function/arity>"}, ) <>
           ~s({"exits": "<registered name or pid>"}, {"shapes": "<Module.function/arity>"})

  @doc """
  Validates a trace option (a map or keyword list with one key).

      iex> Porthole.Trace.parse(%{"messages_to" => "Shop.Notifications"})
      {:ok, {:messages_to, {:name, ["Elixir.Shop.Notifications", "Shop.Notifications"]}}}

      iex> Porthole.Trace.parse(calls: "Shop.Pricing.quote/1")
      {:ok, {:calls, {["Elixir.Shop.Pricing", "Shop.Pricing"], "quote", 1}}}

  """
  @spec parse(map() | keyword() | nil) :: {:ok, t() | nil} | {:error, Error.t()}
  def parse(nil), do: {:ok, nil}

  def parse(spec) when is_map(spec) or is_list(spec) do
    pairs = if is_map(spec), do: Map.to_list(spec), else: spec

    case pairs do
      [{kind, value}] when is_binary(value) ->
        case Map.fetch(@kinds, to_string(kind)) do
          {:ok, kind} -> parse(kind, String.trim(value))
          :error -> bad_request(@usage)
        end

      _other ->
        bad_request(@usage)
    end
  rescue
    # A keyword-like list that is not one.
    _ in [ArgumentError, Protocol.UndefinedError] -> bad_request(@usage)
  end

  def parse(_other), do: bad_request(@usage)

  defp parse(:calls, text) do
    case Regex.run(~r/^(:?)([\w.]+?)(?:\.([a-z_]\w*[?!]?)\/(\d{1,3}))?$/, text) do
      [_, colon, module] ->
        {:ok, {:calls, {modules(colon, module), nil, nil}}}

      [_, colon, module, function, arity] ->
        {:ok, {:calls, {modules(colon, module), function, String.to_integer(arity)}}}

      nil ->
        bad_request(
          ~s{calls must be a module ("Shop.Pricing") or a function with its arity } <>
            ~s{("Shop.Pricing.quote/1"), got #{inspect(text)}}
        )
    end
  end

  defp parse(:shapes, text) do
    case parse(:calls, text) do
      {:ok, {:calls, {modules, function, arity}}} when function != nil ->
        {:ok, {:shapes, {modules, function, arity}}}

      _not_a_function ->
        bad_request(
          ~s{shapes must be one function with its arity ("Shop.Payments.parse/1"), } <>
            ~s{got #{inspect(text)}}
        )
    end
  end

  defp parse(kind, text) do
    case process(text) do
      {:ok, target} ->
        {:ok, {kind, target}}

      :error ->
        bad_request(
          "#{kind} must be a registered name (as in processes.registered_name) or a pid " <>
            "(as in processes.pid), got #{inspect(text)}"
        )
    end
  end

  defp process(text) do
    cond do
      match = Regex.run(~r/^(?:#PID)?<\d+\.(\d+)\.(\d+)>$/, text) ->
        [_, id, serial] = match
        # Pids are rendered as their own node sees them: always <0.X.Y>.
        {:ok, {:pid, String.to_charlist("<0.#{id}.#{serial}>")}}

      text =~ ~r/^:?[\w.@]+$/ ->
        name = String.trim_leading(text, ":")
        {:ok, {:name, ["Elixir." <> name, name]}}

      true ->
        :error
    end
  end

  defp modules(":", module), do: [module]
  defp modules("", module), do: ["Elixir." <> module, module]

  @doc "The table holding the results of `trace`."
  @spec table(t()) :: module()
  def table({:messages_to, _}), do: Tables.TraceMessages
  def table({:calls, _}), do: Tables.TraceCalls
  def table({:exits, _}), do: Tables.TraceExits
  def table({:shapes, _}), do: Tables.TraceShapes

  @doc "The trace option that fills `table`, as the agent writes it."
  @spec usage(module()) :: String.t()
  def usage(Tables.TraceMessages), do: ~s(trace: {"messages_to": "<registered name or pid>"})
  def usage(Tables.TraceCalls), do: ~s(trace: {"calls": "<Module or Module.function/arity>"})
  def usage(Tables.TraceExits), do: ~s(trace: {"exits": "<registered name or pid>"})
  def usage(Tables.TraceShapes), do: ~s(trace: {"shapes": "<Module.function/arity>"})

  @doc "Whether `trace` targets one pid (which only means something on one node)."
  @spec pid?(t()) :: boolean()
  def pid?({_kind, {:pid, _}}), do: true
  def pid?(_trace), do: false

  @doc "What `trace` targets, as the agent wrote it."
  @spec describe(t()) :: String.t()
  def describe({_kind, {:pid, pid}}), do: "#PID#{pid}"
  def describe({_kind, {:name, [_elixir, name]}}), do: name

  def describe({kind, {modules, function, arity}}) when kind in [:calls, :shapes],
    do: describe_calls(modules, function, arity)

  defp describe_calls(modules, nil, nil), do: List.last(modules)
  defp describe_calls(modules, function, arity), do: "#{List.last(modules)}.#{function}/#{arity}"

  @doc """
  Notes for the agent about one node's trace: why nothing was traced there
  (`:info`), or what a limit left out (`:cut`, which makes the result
  `truncated`).
  """
  @spec notes(map(), t(), pos_integer(), pos_integer()) :: [{:cut | :info, String.t()}]
  def notes(raw, trace, window_ms, max_rows) do
    target = describe(trace)

    case raw do
      %{status: :not_found} ->
        [{:info, "#{target} is not running on this node: nothing was traced here"}]

      %{status: :not_loaded} ->
        [
          {:info,
           "no module #{target} is loaded on this node: nothing was traced here (modules " <>
             "can load on first use; check the name)"}
        ]

      %{status: :refused} ->
        [
          {:info,
           "#{target} is part of OTP or Elixir: tracing it would slow down the whole node, " <>
             "trace the application's own modules"}
        ]

      %{status: :no_function} ->
        [{:info, "#{target}: no such function on this node, nothing was traced here"}]

      %{status: :ok} = raw ->
        List.flatten([
          if(raw.stopped == :events,
            do:
              {:cut,
               "the trace reached its event limit (max_trace_events) after " <>
                 "#{Enum.min([raw.elapsed_ms, window_ms])} ms of the #{window_ms} ms window " <>
                 "and stopped: the rows are a sample of that time"},
            else: []
          ),
          if(raw.read == :deadline,
            do:
              {:cut,
               "the node was too busy to read every event in time (tracing runs at low " <>
                 "priority): only the first #{raw.events} events are included"},
            else: []
          ),
          if(raw.truncated,
            do: {:cut, "only the first #{max_rows} rows were kept (max_rows)"},
            else: []
          )
        ])
    end
  end

  @doc """
  Renders who a process is, as the node identified it: its registered name
  and initial call, as `processes` shows them (a supervisor's as
  `Mod.init/1`), and who started it (a name, or else an initial call).
  """
  @spec identity(tuple() | nil) :: {String.t() | nil, String.t() | nil, String.t() | nil}
  def identity({name, call, started_by}),
    do: {if(name, do: Porthole.Term.name(name)), initial_call(call), who(started_by)}

  def identity(_unknown), do: {nil, nil, nil}

  # A process as one text: its registered name, or else its initial call.
  defp who({name, _call}) when name != nil, do: Porthole.Term.name(name)
  defp who({nil, call}), do: initial_call(call)
  defp who(_unknown), do: nil

  defp initial_call({:supervisor, module, 1}), do: Porthole.Term.mfa({module, :init, 1})
  defp initial_call(call), do: Porthole.Term.mfa(call)

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

  @doc """
  The name of an exception or error class as Elixir developers see it:
  `:function_clause` becomes `"FunctionClauseError"`, a module its name.
  """
  @spec exception_name(atom()) :: String.t()
  def exception_name(reason) when is_atom(reason),
    do: Porthole.Term.name(Map.get(@exceptions, reason, reason))

  @doc ~S"""
  Renders a shape (see `Porthole.Gather.trace/7`) as Elixir-like text: types
  and sizes in place of values.

      iex> Porthole.Trace.render_shape({:tuple, [{:atom, :ok}, {:map, 2, [{"amount", {:binary, 5}}, {"currency", {:binary, 3}}]}]})
      ~s({:ok, %{"amount" => binary(5), "currency" => binary(3)}})

  """
  @spec render_shape(term()) :: String.t()
  def render_shape(:more), do: "…"
  def render_shape({:atom, atom}), do: inspect(atom)
  def render_shape({:binary, size}), do: "binary(#{size})"
  def render_shape({:list, 0, _}), do: "[]"
  def render_shape({:list, -1, first}), do: "improper_list(#{render_shape(first)}, …)"
  def render_shape({:list, length, first}), do: "list(#{length}) of #{render_shape(first)}"
  def render_shape({:tuple, size}) when is_integer(size), do: "tuple(#{size})"

  def render_shape({:tuple, elements}),
    do: "{" <> Enum.map_join(elements, ", ", &render_shape/1) <> "}"

  def render_shape({:struct, struct, size, fields}) do
    shown = Enum.map(fields, fn {key, value} -> "#{key}: #{render_shape(value)}" end)
    "%#{Porthole.Term.name(struct)}{" <> Enum.join(shown ++ more(size, fields), ", ") <> "}"
  end

  def render_shape({:map, size, pairs}) do
    shown =
      Enum.map(pairs, fn
        {key, value} when is_atom(key) -> "#{key}: #{render_shape(value)}"
        {key, value} -> "#{render_key(key)} => #{render_shape(value)}"
      end)

    "%{" <> Enum.join(shown ++ more(size, pairs), ", ") <> "}"
  end

  def render_shape(type) when is_atom(type), do: Atom.to_string(type)

  defp render_key(key) when is_integer(key) or is_binary(key), do: inspect(key)
  defp render_key(shape), do: render_shape(shape)

  defp more(size, shown) when size > length(shown), do: ["… (#{size - length(shown)} more)"]
  defp more(_size, _shown), do: []

  @doc """
  A traced call's outcome (`ok`, `error`, `returned` or `raised`) and its
  result as text: the result's shape, or the exception's name.
  """
  @spec outcome(term()) :: {String.t(), String.t()}
  def outcome({:returned, shape}) do
    kind =
      case shape do
        {:atom, :ok} -> "ok"
        {:tuple, [{:atom, :ok} | _]} -> "ok"
        {:atom, :error} -> "error"
        {:tuple, [{:atom, :error} | _]} -> "error"
        _other -> "returned"
      end

    {kind, render_shape(shape)}
  end

  def outcome({:raised, reason}), do: {"raised", exception_name(reason)}

  defp bad_request(message), do: {:error, Error.new(:bad_request, message)}
end

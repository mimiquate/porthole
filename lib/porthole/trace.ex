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
      every process it starts, with the reason's class, in `trace_exits`.

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

  @kinds %{"messages_to" => :messages_to, "calls" => :calls, "exits" => :exits}

  @usage ~s(trace must be one of {"messages_to": "<registered name or pid>"}, ) <>
           ~s({"calls": "<Module>" or "<Module.function/arity>"}, ) <>
           ~s({"exits": "<registered name or pid>"})

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

  @doc "The trace option that fills `table`, as the agent writes it."
  @spec usage(module()) :: String.t()
  def usage(Tables.TraceMessages), do: ~s(trace: {"messages_to": "<registered name or pid>"})
  def usage(Tables.TraceCalls), do: ~s(trace: {"calls": "<Module or Module.function/arity>"})
  def usage(Tables.TraceExits), do: ~s(trace: {"exits": "<registered name or pid>"})

  @doc "Whether `trace` targets one pid (which only means something on one node)."
  @spec pid?(t()) :: boolean()
  def pid?({_kind, {:pid, _}}), do: true
  def pid?(_trace), do: false

  @doc "What `trace` targets, as the agent wrote it."
  @spec describe(t()) :: String.t()
  def describe({_kind, {:pid, pid}}), do: "#PID#{pid}"
  def describe({_kind, {:name, [_elixir, name]}}), do: name
  def describe({:calls, {modules, function, arity}}), do: describe_calls(modules, function, arity)

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

  defp bad_request(message), do: {:error, Error.new(:bad_request, message)}
end

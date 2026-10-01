defmodule Porthole.Remote do
  @moduledoc """
  Runs Porthole's collection code on a node that has no Porthole code at all.

  The node evaluates a small, fixed piece of Erlang (with `:erl_eval`, part of
  OTP itself) that only *reads*: it calls the VM's introspection functions
  and returns the raw data. Nothing is compiled or loaded on the node, so
  nothing is left behind, and the node only needs OTP 27+: no Porthole, not
  even Elixir.

  The code that runs is always Porthole's own, written here: agents never
  send code, only SQL, which runs on the querying node. Evaluating it needs
  nothing beyond the distribution cookie the querying node already holds.

  Every evaluation runs with the same safeguards as compiled collection:

    * in a separate, **low-priority** worker, so the application wins under
      load;
    * with a **deadline enforced on the node**: past it, the worker is killed
      there (`:erpc` itself does not stop remote work when the caller times
      out);
    * excluding the processes doing the collection from what it sees.
  """

  @typedoc "Erlang source of a fun taking the caller's pid and returning the result."
  @type gather_source :: String.t()

  # Runs the gather fun in a low-priority worker and enforces the deadline on
  # the node. `Gather`, `Budget` and the gather fun's own bindings are bound
  # by `run/4`.
  @wrapper """
  Caller = self(),
  {Worker, Ref} = erlang:spawn_monitor(fun() ->
      erlang:process_flag(priority, low),
      Caller ! {porthole_result, self(), Gather(Caller)}
    end),
  receive
    {porthole_result, Worker, Result} ->
      erlang:demonitor(Ref, [flush]),
      {ok, Result};
    {'DOWN', Ref, process, Worker, Reason} ->
      {error, Reason}
  after Budget ->
    erlang:exit(Worker, kill),
    erlang:demonitor(Ref, [flush]),
    {error, timeout}
  end.
  """

  @doc """
  Evaluates `gather_source` on `node` with `bindings` (Erlang variable names
  as atoms, e.g. `%{Max: 100}`), within `budget` milliseconds on the node.
  """
  @spec run(node(), gather_source(), map(), pos_integer()) :: {:ok, term()} | {:error, term()}
  def run(node, gather_source, bindings, budget) do
    exprs = parse!("Gather = " <> gather_source <> ",\n" <> @wrapper)

    bindings =
      bindings
      |> Map.put(:Budget, budget)
      |> Enum.reduce(:erl_eval.new_bindings(), fn {name, value}, acc ->
        :erl_eval.add_binding(name, value, acc)
      end)

    # A little longer than the on-node deadline, so the node reports its own
    # timeout first.
    case :erpc.call(node, :erl_eval, :exprs, [exprs, bindings], budget + 1_000) do
      {:value, result, _bindings} -> result
    end
  catch
    kind, reason -> {:error, {kind, reason}}
  end

  @doc false
  @spec parse!(String.t()) :: [tuple()]
  def parse!(source) do
    {:ok, tokens, _} = :erl_scan.string(String.to_charlist(source))
    {:ok, exprs} = :erl_parse.parse_exprs(tokens)
    exprs
  end

  @doc """
  Renders a pid the way the node that owns it sees it (`#PID<0.214.0>`),
  wherever it is rendered. Pids from other nodes otherwise render with the
  local node's index for them (`#PID<15623.214.0>`).
  """
  @spec pid(pid()) :: String.t()
  def pid(pid) when is_pid(pid) do
    [_node_index | rest] = pid |> :erlang.pid_to_list() |> to_string() |> String.split(".")
    "#PID<0." <> Enum.join(rest, ".")
  end
end

defmodule Porthole.Remote do
  @moduledoc """
  Runs Porthole's collection code on a node that does not have Porthole as a
  dependency (any Elixir app on OTP 27+).

  The node evaluates the compiled code of a `Porthole.Gather` function (with
  `:erl_eval`, part of OTP itself). That code only *reads*: it calls the VM's
  introspection functions and returns the raw data. Nothing is compiled or
  loaded on the node, so nothing is left behind.

  The code that runs is always Porthole's own (`Porthole.Gather`, checked
  when it compiles): agents never send code, only SQL, which runs on the
  querying node. Evaluating it needs nothing beyond the distribution cookie
  the querying node already holds.

  Every evaluation runs with the same safeguards as compiled collection:

    * in a separate, **low-priority** worker, so the application wins under
      load;
    * with a **deadline enforced on the node**: past it, the worker is killed
      there (`:erpc` itself does not stop remote work when the caller times
      out);
    * excluding the processes doing the collection from what it sees.
  """

  @doc """
  Runs `Porthole.Gather.name(caller, args...)` on `node` by evaluation,
  within `budget` milliseconds on the node (`Porthole.Gather.with_deadline/3`).
  """
  @spec run(node(), atom(), list(), pos_integer()) :: {:ok, term()} | {:error, term()}
  def run(node, name, args, budget) do
    # Evaluated on the node:  Run = fun ..., Gather = fun ..., Run(Gather, Args, Budget)
    exprs = [
      {:match, 1, {:var, 1, :Run}, Porthole.Gather.Code.fun_expr(:with_deadline, 3)},
      {:match, 1, {:var, 1, :Gather}, Porthole.Gather.Code.fun_expr(name, length(args) + 1)},
      {:call, 1, {:var, 1, :Run}, [{:var, 1, :Gather}, {:var, 1, :Args}, {:var, 1, :Budget}]}
    ]

    bindings =
      :erl_eval.new_bindings()
      |> then(&:erl_eval.add_binding(:Args, args, &1))
      |> then(&:erl_eval.add_binding(:Budget, budget, &1))

    # A little longer than the on-node deadline, so the node reports its own
    # timeout first.
    case :erpc.call(node, :erl_eval, :exprs, [exprs, bindings], budget + 1_000) do
      {:value, result, _bindings} -> result
    end
  catch
    kind, reason -> {:error, {kind, reason}}
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

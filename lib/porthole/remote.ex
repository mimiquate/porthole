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
    with {:ok, encoded} <- run_encoded(node, name, args, budget) do
      {:ok, :erlang.binary_to_term(encoded)}
    end
  end

  @doc """
  Like `run/4`, but returns the node's result as it arrives: encoded in one
  binary (`:erlang.term_to_binary/1`, done on the node). A large binary is
  shared between processes rather than copied, so the result can be handed
  on and decoded only when it is needed.
  """
  @spec run_encoded(node(), atom(), list(), pos_integer()) :: {:ok, binary()} | {:error, term()}
  def run_encoded(node, name, args, budget) do
    # Evaluated on the node:
    #   Run = fun ..., Gather = fun ...,
    #   case Run(Gather, Args, Budget) of {ok, R} -> {ok, term_to_binary(R)}; E -> E end
    exprs = [
      {:match, 1, {:var, 1, :Run}, Porthole.Gather.Code.fun_expr(:with_deadline, 3)},
      {:match, 1, {:var, 1, :Gather}, Porthole.Gather.Code.fun_expr(name, length(args) + 1)},
      {:case, 1,
       {:call, 1, {:var, 1, :Run}, [{:var, 1, :Gather}, {:var, 1, :Args}, {:var, 1, :Budget}]},
       [
         {:clause, 1, [{:tuple, 1, [{:atom, 1, :ok}, {:var, 1, :R}]}], [],
          [
            {:tuple, 1,
             [
               {:atom, 1, :ok},
               {:call, 1, {:remote, 1, {:atom, 1, :erlang}, {:atom, 1, :term_to_binary}},
                [{:var, 1, :R}]}
             ]}
          ]},
         {:clause, 1, [{:var, 1, :E}], [], [{:var, 1, :E}]}
       ]}
    ]

    # A map, not the default orddict: the gather code binds many variables
    # per process, and lookups in an orddict made evaluation 2-3x slower.
    bindings = %{Args: args, Budget: budget}

    # A little longer than the on-node deadline, so the node reports its own
    # timeout first.
    case :erpc.call(node, :erl_eval, :exprs, [exprs, bindings], budget + 1_000) do
      {:value, result, _bindings} -> result
    end
  catch
    kind, reason -> {:error, {kind, reason}}
  end

  @doc """
  Renders a pid, port or reference the way the node that owns it sees it
  (`#PID<0.214.0>`, `#Port<0.16>`), wherever it is rendered. Rendered on
  another node, they would carry that node's index for their owner instead
  (`#PID<15623.214.0>`).
  """
  @spec pid(pid() | port() | reference()) :: String.t()
  def pid(term) when is_pid(term) or is_port(term) or is_reference(term) do
    String.replace(inspect(term), ~r/<\d+\./, "<0.", global: false)
  end
end

defmodule Porthole.Tables.TraceCalls do
  @moduledoc """
  Call counts and running time of a module's functions during a trace
  (`trace: %{calls: ...}`), per process. Counted by the VM: no event is sent
  per call. Join `pid` with `processes.pid`.
  """

  @behaviour Porthole.Table

  alias Porthole.{Remote, Term}

  @impl true
  def name, do: "trace_calls"

  @impl true
  def description,
    do:
      ~s(With trace {"calls": "<Module or Module.function/arity>"}: one row per process ) <>
        "and function called during the window, with how often and how long. Answers " <>
        "where a process spends its time and who calls a function."

  @impl true
  def key, do: :pid

  @impl true
  def deltas, do: []

  @impl true
  def columns do
    [
      {:pid, :text, "Pid of the process that ran the function (join processes.pid)."},
      {:function, :text, "Mod.fun/arity."},
      {:calls, :integer, "Calls during the window."},
      {:time_us, :integer,
       "CPU time running the function's own code, in µs. Not latency: waiting (receive, " <>
         "I/O, a GenServer.call, a database query) counts ~0, so a call that waits 200 ms " <>
         "for the database shows a few µs. Time in other traced functions is excluded."}
    ]
  end

  @impl true
  def gather(limits) do
    {:calls, calls} = limits.trace
    {:trace_calls, [limits.querier, calls, limits.window_ms, limits.max_rows]}
  end

  @impl true
  def shape(raw) do
    rows =
      for {pid, mfa, calls, time_us} <- Map.get(raw, :rows, []) do
        %{pid: Remote.pid(pid), function: Term.mfa(mfa), calls: calls, time_us: time_us}
      end

    {rows, {:trace, Map.delete(raw, :rows)}}
  end
end

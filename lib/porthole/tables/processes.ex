defmodule Porthole.Tables.Processes do
  @moduledoc """
  One row per process.

  Uses `Process.info/2` with an explicit item list, reading process dictionary
  entries key by key, so no process is copied in full.
  """

  @behaviour Porthole.Table

  alias Porthole.{Table, Term}

  @items [
    :registered_name,
    :initial_call,
    {:dictionary, :"$initial_call"},
    {:dictionary, :"$ancestors"},
    {:dictionary, :"$process_label"},
    :current_function,
    :status,
    :message_queue_len,
    :memory,
    :binary,
    :reductions,
    :links,
    :monitors,
    :monitored_by,
    :group_leader
  ]

  @impl true
  def name, do: "processes"

  @impl true
  def description,
    do: "One row per process: identity, what spawned it, mailbox, memory, reductions."

  @impl true
  def key, do: :pid

  @impl true
  def deltas, do: [:reductions, :memory, :message_queue_len, :binary_memory]

  @impl true
  def columns do
    [
      {:pid, :text, "e.g. #PID<0.123.0>"},
      {:registered_name, :text, "Registered name, if any."},
      {:initial_call, :text,
       "What the process runs: the GenServer/Supervisor/Task module (e.g. MyApp.Cache.init/1)."},
      {:current_function, :text, "Function executing now."},
      {:waiting_on, :text,
       "When blocked in GenServer.call (or any gen call) or Task.await: the pid being waited on. Join with processes.pid."},
      {:label, :text, "Label from Process.set_label/1."},
      {:application, :text, "OTP application the process belongs to."},
      {:ancestors, :text, "Spawning processes (pids or names), nearest first, comma separated."},
      {:status, :text, "running | runnable | waiting | exiting | garbage_collecting | suspended"},
      {:message_queue_len, :integer, "Messages in the mailbox."},
      {:memory, :integer, "Bytes."},
      {:binary_memory, :integer,
       "Bytes of refc binaries referenced (shared ones count for every holder)."},
      {:reductions, :integer, "Work done since start."},
      {:links_count, :integer, "Linked processes and ports."},
      {:monitors_count, :integer, "Monitors this process holds."},
      {:monitored_by_count, :integer, "Processes monitoring this one."}
    ]
  end

  @impl true
  def collect(max_rows) do
    applications = application_masters()
    {pids, truncated} = Table.take(Process.list(), max_rows)

    rows =
      for pid <- pids, info = Process.info(pid, @items), info != nil do
        row(pid, Map.new(info), applications)
      end

    {rows, truncated}
  end

  defp row(pid, info, applications) do
    %{
      pid: inspect(pid),
      registered_name:
        if(info.registered_name == [], do: nil, else: Term.name(info.registered_name)),
      initial_call: initial_call(info[{:dictionary, :"$initial_call"}], info.initial_call),
      current_function: Term.mfa(info.current_function),
      waiting_on: waiting_on(info.current_function, info.monitors),
      label: label(info[{:dictionary, :"$process_label"}]),
      application: applications[info.group_leader],
      ancestors: ancestors(info[{:dictionary, :"$ancestors"}]),
      status: Atom.to_string(info.status),
      message_queue_len: info.message_queue_len,
      memory: info.memory,
      binary_memory: Enum.sum_by(info.binary, &elem(&1, 1)),
      reductions: info.reductions,
      links_count: length(info.links),
      monitors_count: length(info.monitors),
      monitored_by_count: length(info.monitored_by)
    }
  end

  # Like :proc_lib.translate_initial_call/1: OTP behaviours record their
  # callback module in $initial_call. Supervisors record {supervisor, Mod, 1},
  # whose code is Mod.init/1.
  defp initial_call({:supervisor, module, 1}, _raw), do: Term.mfa({module, :init, 1})
  defp initial_call({_, _, _} = mfa, _raw), do: Term.mfa(mfa)
  defp initial_call(_undefined, raw), do: Term.mfa(raw)

  # A process blocked in a gen call (GenServer, :gen_statem, Agent, Supervisor
  # calls) or in Task.await monitors its target while it waits, and that is
  # its most recent monitor. Best effort: the order of the monitors list is
  # not documented, so this relies on observed VM behavior.
  @blocking_calls [{:gen, :do_call, 4}, {Task, :await_receive, 3}]

  defp waiting_on(current, [_ | _] = monitors) when current in @blocking_calls do
    case List.last(monitors) do
      {:process, pid} when is_pid(pid) -> inspect(pid)
      {:process, {name, node}} -> "#{Term.name(name)}@#{node}"
      _port -> nil
    end
  end

  defp waiting_on(_current, _monitors), do: nil

  defp label(:undefined), do: nil
  defp label(label), do: Term.render(label)

  defp ancestors([_ | _] = ancestors) do
    Enum.map_join(ancestors, ",", fn
      name when is_atom(name) -> Term.name(name)
      pid -> inspect(pid)
    end)
  end

  defp ancestors(_none), do: nil

  # Processes started by an application have its master as group leader.
  defp application_masters do
    for {app, _, _} <- Application.started_applications(),
        master = :application_controller.get_master(app),
        is_pid(master),
        into: %{},
        do: {master, Atom.to_string(app)}
  end
end

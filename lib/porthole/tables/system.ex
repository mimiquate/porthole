defmodule Porthole.Tables.System do
  @moduledoc """
  One row per node: VM memory by category, counts against their limits, and
  scheduler load. Usually the first query in an investigation.
  """

  @behaviour Porthole.Table

  @impl true
  def name, do: "system"

  @impl true
  def description,
    do:
      "One row per node: memory by category, process/atom/port/ETS counts vs limits, run queue. Start here."

  # There is a single row per node; the release never changes during a window.
  @impl true
  def key, do: :otp_release

  @impl true
  def deltas,
    do: [
      :memory_total,
      :memory_processes,
      :memory_binary,
      :memory_ets,
      :process_count,
      :port_count,
      :reductions
    ]

  @impl true
  def columns do
    [
      {:otp_release, :text, "OTP release, e.g. 27."},
      {:elixir_version, :text, "Elixir version."},
      {:uptime_ms, :integer, "Milliseconds since the VM started."},
      {:schedulers_online, :integer, "Schedulers running Erlang code."},
      {:run_queue, :integer,
       "Processes ready to run but waiting for a scheduler. Persistently > schedulers means CPU saturation."},
      {:process_count, :integer, "Processes alive."},
      {:process_limit, :integer, "Maximum processes (+P)."},
      {:atom_count, :integer, "Atoms in the atom table (never garbage collected)."},
      {:atom_limit, :integer, "Maximum atoms (+t). Reaching it crashes the VM."},
      {:port_count, :integer, "Ports open."},
      {:port_limit, :integer, "Maximum ports (+Q)."},
      {:ets_count, :integer, "ETS tables."},
      {:ets_limit, :integer, "ETS table limit (+e)."},
      {:reductions, :integer, "Reductions executed by the whole VM since start."},
      {:memory_total, :integer, "Bytes allocated by the VM."},
      {:memory_processes, :integer, "Bytes used by processes."},
      {:memory_binary, :integer, "Bytes used by refc binaries."},
      {:memory_ets, :integer, "Bytes used by ETS tables."},
      {:memory_atom, :integer, "Bytes used by atoms."},
      {:memory_code, :integer, "Bytes used by loaded code."},
      {:memory_system, :integer, "Bytes not attributed to processes."}
    ]
  end

  @impl true
  def collect(_max_rows) do
    memory = :erlang.memory()
    {total_reductions, _since_last} = :erlang.statistics(:reductions)

    row = %{
      otp_release: to_string(:erlang.system_info(:otp_release)),
      elixir_version: System.version(),
      uptime_ms: elem(:erlang.statistics(:wall_clock), 0),
      schedulers_online: :erlang.system_info(:schedulers_online),
      run_queue: :erlang.statistics(:total_run_queue_lengths),
      process_count: :erlang.system_info(:process_count),
      process_limit: :erlang.system_info(:process_limit),
      atom_count: :erlang.system_info(:atom_count),
      atom_limit: :erlang.system_info(:atom_limit),
      port_count: :erlang.system_info(:port_count),
      port_limit: :erlang.system_info(:port_limit),
      ets_count: :erlang.system_info(:ets_count),
      ets_limit: :erlang.system_info(:ets_limit),
      reductions: total_reductions,
      memory_total: memory[:total],
      memory_processes: memory[:processes],
      memory_binary: memory[:binary],
      memory_ets: memory[:ets],
      memory_atom: memory[:atom],
      memory_code: memory[:code],
      memory_system: memory[:system]
    }

    {[row], false}
  end
end

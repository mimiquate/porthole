defmodule Porthole.Gather do
  @moduledoc """
  The code that runs on observed nodes: it reads the VM's introspection data
  and returns it raw, for the querying node to shape into rows.

  These are ordinary, compiled functions. The querying node calls them
  directly for itself; every other node gets the same functions' compiled
  code sent over and evaluated (see `Porthole.Remote`), whether or not it
  has Porthole, so nothing is ever loaded there.

  For that to work on any node, every function in this module follows two
  rules, **checked when this module compiles** (a violation fails the build):

    * **Calls only OTP modules** (`:erlang`, `:lists`, ...), plus
      `Enum.reduce/3`, which `for` comprehensions compile to and which has
      existed since Elixir 1.0. The node may run another Elixir version than
      the querying node, so newer Elixir functions might not exist there.
    * **No calls to other functions of this module**: an evaluated function
      cannot see its siblings. Helpers are anonymous functions instead.

  Everything here only reads. Agents never send code: the only code that
  runs on a node is this module's.
  """

  # Checks the rules above and keeps each function's compiled code for
  # Porthole.Remote (see Porthole.Gather.Check).
  @after_compile Porthole.Gather.Check

  @doc """
  Runs `gather` (with the caller's pid prepended to `args`) in a low-priority
  worker, killing it if it takes longer than `budget` milliseconds. This is
  the node-side safeguard around every collection. A failure in `gather` is
  returned as `{:error, {kind, reason}}`, never logged on the node.
  """
  @spec with_deadline(fun(), list(), pos_integer()) :: {:ok, term()} | {:error, term()}
  def with_deadline(gather, args, budget) do
    case :erlang.list_to_integer(:erlang.system_info(:otp_release)) do
      release when release < 27 ->
        {:error, {:old_otp, release}}

      _release ->
        caller = :erlang.self()

        {worker, ref} =
          :erlang.spawn_monitor(fn ->
            :erlang.process_flag(:priority, :low)

            # A crash would be logged on the node (and reach the app's error
            # tracker): failures are returned instead.
            result =
              try do
                {:ok, :erlang.apply(gather, [caller | args])}
              catch
                kind, reason ->
                  case {kind, reason, __STACKTRACE__} do
                    # Gather code uses Enum.reduce/3 (what `for` compiles to).
                    {:error, :undef, [{Enum, _fun, _args, _location} | _]} -> {:error, :no_elixir}
                    _other -> {:error, {kind, reason}}
                  end
              end

            :erlang.send(caller, {:porthole_result, :erlang.self(), result})
          end)

        receive do
          {:porthole_result, ^worker, result} ->
            :erlang.demonitor(ref, [:flush])
            result

          {:DOWN, ^ref, :process, ^worker, reason} ->
            {:error, reason}
        after
          budget ->
            :erlang.exit(worker, :kill)
            :erlang.demonitor(ref, [:flush])
            {:error, :timeout}
        end
    end
  end

  @doc """
  Process info for every process except the collecting ones (the worker and
  `caller`), at most `max`, with large lists reduced to what the `processes`
  columns need. Also returns the application masters, to attribute processes
  to applications.
  """
  @spec processes(pid(), [atom() | tuple()], pos_integer()) :: map()
  def processes(caller, items, max) do
    me = :erlang.self()
    all = for pid <- :erlang.processes(), pid != me, pid != caller, do: pid

    compact = fn
      {:binary, bins} ->
        {:binary_memory, :lists.foldl(fn {_id, size, _refs}, acc -> acc + size end, 0, bins)}

      {:links, links} ->
        {:links_count, :erlang.length(links)}

      {:monitored_by, by} ->
        {:monitored_by_count, :erlang.length(by)}

      {:monitors, []} ->
        {:monitors, {0, :none}}

      {:monitors, monitors} ->
        {:monitors, {:erlang.length(monitors), :lists.last(monitors)}}

      other ->
        other
    end

    masters =
      for {app, _description, _vsn} <- :application.which_applications(),
          master = :application_controller.get_master(app),
          :erlang.is_pid(master),
          do: {master, app}

    rows =
      for pid <- :lists.sublist(all, max),
          info = :erlang.process_info(pid, items),
          info != :undefined,
          do: {pid, :lists.map(compact, info)}

    %{rows: rows, truncated: :erlang.length(all) > max, masters: masters}
  end

  @doc """
  Every supervisor's children (`which_children`, with `call_timeout`), at
  most `max` children overall. Supervisors are recognized by their
  `$initial_call`; one that does not answer in time is reported as
  `:unreachable`.
  """
  @spec supervisors(pid(), pos_integer(), timeout()) :: map()
  def supervisors(caller, max, call_timeout) do
    me = :erlang.self()

    supervisors =
      for pid <- :erlang.processes(),
          pid != me,
          pid != caller,
          info = :erlang.process_info(pid, [{:dictionary, :"$initial_call"}, :registered_name]),
          info != :undefined,
          [{_, {:supervisor, module, _}}, {_, name}] <- [info],
          do: {pid, module, name}

    # gen_server calls use aliases, so a late reply is dropped instead of
    # landing in this process's mailbox.
    children = fn pid ->
      try do
        {:ok, :gen_server.call(pid, :which_children, call_timeout)}
      catch
        :exit, _ -> :unreachable
      end
    end

    rows =
      for {pid, module, name} <- supervisors,
          child <-
            (case children.(pid) do
               {:ok, list} -> list
               :unreachable -> [:unreachable]
             end),
          do: {pid, module, name, child}

    %{rows: :lists.sublist(rows, max), truncated: :erlang.length(rows) > max}
  end

  @doc "`:ets.info/1` of every ETS table (metadata only), at most `max`."
  @spec ets_tables(pid(), pos_integer()) :: map()
  def ets_tables(_caller, max) do
    all = :ets.all()

    # A table deleted mid-walk makes :ets.info/1 return :undefined.
    rows =
      for table <- :lists.sublist(all, max),
          info = :ets.info(table),
          info != :undefined,
          do: {table, info}

    %{
      rows: rows,
      truncated: :erlang.length(all) > max,
      word_size: :erlang.system_info(:wordsize)
    }
  end

  @doc """
  `:erlang.port_info/1` of every port, at most `max`, with memory, queue size
  and, for sockets, local and remote addresses.
  """
  @spec ports(pid(), pos_integer()) :: map()
  def ports(_caller, max) do
    all = :erlang.ports()
    sockets = [~c"tcp_inet", ~c"udp_inet", ~c"sctp_inet"]

    # A port closed mid-walk makes port_info return :undefined.
    rows =
      for port <- :lists.sublist(all, max),
          info = :erlang.port_info(port),
          info != :undefined,
          {:memory, memory} <- [:erlang.port_info(port, :memory)],
          {:queue_size, queue_size} <- [:erlang.port_info(port, :queue_size)] do
        addresses =
          case :lists.member(:proplists.get_value(:name, info), sockets) do
            true -> {:inet.sockname(port), :inet.peername(port)}
            false -> :none
          end

        {port, info, memory, queue_size, addresses}
      end

    %{rows: rows, truncated: :erlang.length(all) > max}
  end

  @doc "Loaded and running applications."
  @spec applications(pid()) :: map()
  def applications(_caller) do
    %{loaded: :application.loaded_applications(), running: :application.which_applications()}
  end

  @doc "VM-wide memory, counts, limits and load."
  @spec system(pid()) :: map()
  def system(_caller) do
    {reductions, _since_last} = :erlang.statistics(:reductions)
    {uptime_ms, _since_last} = :erlang.statistics(:wall_clock)

    %{
      memory: :erlang.memory(),
      otp_release: :erlang.system_info(:otp_release),
      elixir_vsn: :application.get_key(:elixir, :vsn),
      uptime_ms: uptime_ms,
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
      reductions: reductions
    }
  end
end

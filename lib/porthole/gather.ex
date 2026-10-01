defmodule Porthole.Gather do
  @moduledoc """
  The code that runs on observed nodes: it reads the VM's introspection data
  and returns it raw, for the querying node to shape into rows.

  These are ordinary, compiled functions. Nodes that have Porthole as a
  dependency run them directly. Nodes that don't, get the same functions'
  compiled code sent over and evaluated (see `Porthole.Remote`), so nothing
  is ever loaded there.

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
  the node-side safeguard around every collection.
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

            :erlang.send(
              caller,
              {:porthole_result, :erlang.self(), :erlang.apply(gather, [caller | args])}
            )
          end)

        receive do
          {:porthole_result, ^worker, result} ->
            :erlang.demonitor(ref, [:flush])
            {:ok, result}

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
end

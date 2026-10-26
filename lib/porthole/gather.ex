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
      `Enum.reduce/3`, which `for` comprehensions with a filter compile to
      and which has existed since Elixir 1.0 (a `for` without a filter
      compiles to `Enum.map/2`: use `:lists.map/2`). The node may run another
      Elixir version than the querying node, so newer Elixir functions might
      not exist there.
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
  `caller`), at most `max`. Each row is a tuple, with large lists reduced to
  what the `processes` columns need:

      {pid, registered_name, initial_call, $initial_call, $ancestors,
       $process_label, current_function, status, message_queue_len, memory,
       binary_memory, reductions, links_count, monitors_count, last_monitor,
       monitored_by_count, group_leader}

  Also returns the application masters, to attribute processes to
  applications.
  """
  @spec processes(pid(), pos_integer()) :: map()
  def processes(caller, max) do
    # Evaluated code pays for every interpreted step, so the work per process
    # is one process_info call and one match, with lists:* (compiled on the
    # node) wherever possible. Compared with mapping a function over each
    # item, this made evaluation ~25% faster and the result 2.5x smaller
    # (100k processes: 1.7 s -> 1.3 s, 47 MB -> 19 MB).
    # Left out: this worker, the process it runs for and, for a query run in
    # a task, the processes waiting on it ($callers).
    callers =
      case :erlang.process_info(caller, {:dictionary, :"$callers"}) do
        {_, [_ | _] = pids} -> pids
        _none -> []
      end

    all = :erlang.processes() -- [:erlang.self(), caller | callers]

    items = [
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

    masters =
      for {app, _description, _vsn} <- :application.which_applications(),
          master = :application_controller.get_master(app),
          :erlang.is_pid(master),
          do: {master, app}

    # A process that exits mid-walk returns :undefined, which does not match.
    rows =
      for pid <- :lists.sublist(all, max),
          [
            {_, name},
            {_, initial_call},
            {_, dictionary_initial_call},
            {_, ancestors},
            {_, label},
            {_, current_function},
            {_, status},
            {_, message_queue_len},
            {_, memory},
            {_, binaries},
            {_, reductions},
            {_, links},
            {_, monitors},
            {_, monitored_by},
            {_, group_leader}
          ] <- [:erlang.process_info(pid, items)] do
        binary_memory =
          case binaries do
            [] -> 0
            _ -> :lists.foldl(fn {_id, size, _refs}, acc -> acc + size end, 0, binaries)
          end

        last_monitor =
          case monitors do
            [] -> :none
            _ -> :lists.last(monitors)
          end

        {pid, name, initial_call, dictionary_initial_call, ancestors, label, current_function,
         status, message_queue_len, memory, binary_memory, reductions, :erlang.length(links),
         :erlang.length(monitors), last_monitor, :erlang.length(monitored_by), group_leader}
      end

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

  @doc """
  Like `supervisors/3`, but walking the applications' supervision trees
  instead of every process: from each application's top supervisor down
  through children of type `:supervisor`. Its cost depends on the number of
  supervisors, not of processes, so it stays fast on large or busy nodes.
  It misses supervisors started outside any application's tree.
  """
  @spec supervision_trees(pid(), pos_integer(), timeout()) :: map()
  def supervision_trees(_caller, max, call_timeout) do
    # {pid, module, registered name} if pid is a supervisor. Only processes
    # recognized this way are sent which_children.
    supervisor = fn pid ->
      case :erlang.process_info(pid, [{:dictionary, :"$initial_call"}, :registered_name]) do
        [{_, {:supervisor, module, _}}, {_, name}] -> {pid, module, name}
        _other -> nil
      end
    end

    linked = fn pid ->
      case :erlang.process_info(pid, :links) do
        {:links, links} -> for link <- links, :erlang.is_pid(link), do: link
        :undefined -> []
      end
    end

    # gen_server calls use aliases, so a late reply is dropped instead of
    # landing in this process's mailbox.
    children = fn pid ->
      try do
        :gen_server.call(pid, :which_children, call_timeout)
      catch
        :exit, _ -> [:unreachable]
      end
    end

    # An application master is linked to a helper process, which is linked
    # to the application's top supervisor.
    roots =
      for {app, _description, _vsn} <- :application.which_applications(),
          master = :application_controller.get_master(app),
          :erlang.is_pid(master),
          helper <- linked.(master),
          pid <- linked.(helper),
          root = supervisor.(pid),
          root != nil,
          do: root

    # Breadth first, each supervisor once, until more than `max` rows.
    walk = fn
      _walk, _queue, _seen, rows, count when count > max ->
        {rows, count}

      _walk, [], _seen, rows, count ->
        {rows, count}

      walk, [{pid, module, name} | queue], seen, rows, count ->
        case :maps.is_key(pid, seen) do
          true ->
            walk.(walk, queue, seen, rows, count)

          false ->
            kids = children.(pid)

            next =
              for {_id, child, :supervisor, _modules} <- kids,
                  :erlang.is_pid(child),
                  sub = supervisor.(child),
                  sub != nil,
                  do: sub

            own = :lists.map(fn kid -> {pid, module, name, kid} end, kids)
            seen = :maps.put(pid, true, seen)
            walk.(walk, queue ++ next, seen, :lists.reverse(own, rows), count + length(kids))
        end
    end

    {rows, count} = walk.(walk, roots, %{}, [], 0)
    %{rows: :lists.sublist(:lists.reverse(rows), max), truncated: count > max}
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

  @doc """
  Traces `spec` for `window_ms` in an OTP trace session, and returns the
  events it kept (at most `max_events` events, `max_rows` rows):

    * `{:messages_to, target}` - messages sent to a process: sender, tag and
      time of each (the message itself is dropped here, on the node);
    * `{:exits, target}` - exits of a process and of every process it starts
      during the window, with the reason's class and where it was raised.

  A target is `{:name, candidates}` (registered names to try) or
  `{:pid, text}`. Names only resolve to atoms that already exist: nothing is
  created on the node.

  The session belongs to this process: when it ends for any reason, the VM
  removes the session and every trace setting it made. It ends at the end of
  the window, when the querying process (`querier`, monitored) goes away, or
  when the events produced reach `max_events`. Events are counted as they are
  produced, not as they are read (evaluated code reads them far slower than
  the VM produces them): this process checks its queue on every event, a
  watchdog at maximum priority checks it every millisecond, and the VM
  kills this process past a heap cap (which also ends the session).

  This process runs at low priority, so on a busy node it may read events
  slowly: events still unread `read_ms` after the trace stopped are left out
  (and reported), rather than letting the whole collection time out.
  """
  @spec trace(pid(), pid(), tuple(), pos_integer(), pos_integer(), pos_integer(), pos_integer()) ::
          map()
  def trace(_caller, querier, spec, window_ms, read_ms, max_events, max_rows) do
    me = self()
    # The events are copies of the traced messages: past this, the VM kills
    # this process, and the session goes with it.
    :erlang.process_flag(:max_heap_size, %{size: 4_000_000, kill: true, error_logger: false})
    querier_ref = :erlang.monitor(:process, querier)
    started = :erlang.monotonic_time(:nanosecond)
    at = fn ts -> div(ts - started, 1_000_000) end

    # -- Which process: the target, if it is running ----------------------

    existing = fn text ->
      try do
        {:ok, :erlang.binary_to_existing_atom(text, :utf8)}
      catch
        :error, _ -> :none
      end
    end

    target =
      case elem(spec, 1) do
        {:pid, text} ->
          try do
            pid = :erlang.list_to_pid(text)
            if :erlang.is_process_alive(pid), do: [pid], else: []
          catch
            :error, _ -> []
          end

        {:name, candidates} ->
          for text <- candidates,
              {:ok, name} <- [existing.(text)],
              pid = :erlang.whereis(name),
              is_pid(pid),
              do: pid

        # A function (shapes): resolved in its plan.
        _function ->
          []
      end

    # -- What is kept of an event ------------------------------------------

    # The atom that says what kind of message `message` is, if it has one
    # (its first element, a struct's name, a GenServer request's own tag).
    tag = fn
      _tag, atom when is_atom(atom) -> atom
      tag, {:"$gen_call", _from, request} -> {:call, tag.(tag, request)}
      tag, {:"$gen_cast", request} -> {:cast, tag.(tag, request)}
      _tag, tuple when tuple_size(tuple) > 0 and is_atom(elem(tuple, 0)) -> elem(tuple, 0)
      _tag, %{__struct__: struct} when is_atom(struct) -> struct
      _tag, _other -> nil
    end

    # An exit reason's class, and where it was raised; never its data.
    location = fn
      [{module, function, arity, _} | _] when is_integer(arity) -> {module, function, arity}
      [{module, function, args, _} | _] when is_list(args) -> {module, function, length(args)}
      _other -> nil
    end

    class = fn
      reason when reason in [:normal, :shutdown, :killed] -> {reason, nil}
      {:shutdown, _} -> {:shutdown, nil}
      {%{__exception__: true, __struct__: struct}, stack} -> {struct, location.(stack)}
      {reason, stack} when is_atom(reason) and is_list(stack) -> {reason, location.(stack)}
      {{reason, _}, stack} when is_atom(reason) and is_list(stack) -> {reason, location.(stack)}
      reason when is_atom(reason) -> {reason, nil}
      reason when tuple_size(reason) > 0 and is_atom(elem(reason, 0)) -> {elem(reason, 0), nil}
      _other -> {:other, nil}
    end

    # Who a process is, asked while it is alive (a row's pid may be gone by
    # the time the agent reads it): {registered name, initial call}, either
    # nil when unknown. $initial_call is set by proc_lib, so it names the
    # module (Mod.init/1) rather than proc_lib's own entry point.
    who = fn pid ->
      case :erlang.process_info(pid, [
             :registered_name,
             {:dictionary, :"$initial_call"},
             :initial_call
           ]) do
        [{_, name}, {_, proc_lib_call}, {_, call}] ->
          name = if name == [], do: nil, else: name
          {name, if(is_tuple(proc_lib_call), do: proc_lib_call, else: call)}

        _gone ->
          nil
      end
    end

    # Who started it: the process it works for ($callers, set by Elixir
    # tasks: e.g. the LiveView behind a preload task), or else its parent
    # ($ancestors, set by proc_lib); one that has exited is skipped.
    started_by = fn callers, ancestors ->
      heads = for list <- [callers, ancestors], is_list(list), list != [], do: hd(list)

      found =
        for candidate <- heads,
            id =
              (case candidate do
                 pid when is_pid(pid) and node(pid) == node() -> who.(pid)
                 name when is_atom(name) -> {name, nil}
                 _other -> nil
               end),
            id != nil,
            do: id

      case found do
        [id | _] -> id
        [] -> nil
      end
    end

    # {registered name, initial call, who started it}.
    identity = fn pid ->
      case :erlang.process_info(pid, [
             :registered_name,
             {:dictionary, :"$initial_call"},
             :initial_call,
             {:dictionary, :"$callers"},
             {:dictionary, :"$ancestors"}
           ]) do
        [{_, name}, {_, proc_lib_call}, {_, call}, {_, callers}, {_, ancestors}] ->
          name = if name == [], do: nil, else: name
          call = if is_tuple(proc_lib_call), do: proc_lib_call, else: call
          {name, call, started_by.(callers, ancestors)}

        _gone ->
          {nil, nil, nil}
      end
    end

    # Who a process was, from how it was spawned: for one that exited before
    # it could be asked. Only names, never the arguments.
    spawned_as = fn
      {:proc_lib, :init_p, [_, _, :gen, :init_it, [_, _, _, _, mod, _, _]]} -> {mod, :init, 1}
      {:proc_lib, :init_p, [_, _, :gen, :init_it, [_, _, _, mod, _, _]]} -> {mod, :init, 1}
      {:proc_lib, :init_p, [_, _, mod, fun, args]} when is_list(args) -> {mod, fun, length(args)}
      {mod, fun, args} when is_list(args) -> {mod, fun, length(args)}
      _other -> nil
    end

    # Identities already known (`known`, pid => identity), or asked once.
    known_identity = fn pid, known ->
      case :maps.find(pid, known) do
        {:ok, id} ->
          {id, known}

        :error ->
          id = identity.(pid)
          {id, :maps.put(pid, id, known)}
      end
    end

    # Flags every process: those spawned from now on in one call, existing
    # ones one at a time from this low-priority process. Flagging them all in
    # one call (:all) blocks the VM's schedulers while it runs: ~17 ms at
    # 100k processes, measured.
    flag_all = fn session, flags ->
      :trace.process(session, :new_processes, true, flags)

      :lists.foreach(
        fn pid ->
          try do
            :trace.process(session, pid, true, flags)
          catch
            # Exited since the list was taken.
            :error, _ -> 0
          end
        end,
        :erlang.processes()
      )
    end

    # Up to 16 keys of a map, without listing (or sorting) all of them: a map
    # can hold millions (sorting 100k keys took 64 ms, per call). Maps of up
    # to 32 keys are stored in key order, so theirs come sorted.
    first_keys = fn map ->
      take = fn take, iterator, n, acc ->
        case n do
          0 ->
            :lists.reverse(acc)

          _ ->
            case :maps.next(iterator) do
              {key, _value, next} -> take.(take, next, n - 1, [key | acc])
              :none -> :lists.reverse(acc)
            end
        end
      end

      take.(take, :maps.iterator(map), 16, [])
    end

    # The shape of a term: its structure without its values. Atoms and map
    # keys are kept (they are names, not data, in most code: see the docs'
    # warning), everything else becomes its type and size. Bounded in depth
    # (4) and width (16 map keys, 8 tuple elements, a list's first element).
    shape = fn
      _shape, _term, depth when depth > 4 ->
        :more

      _shape, atom, _depth when is_atom(atom) ->
        {:atom, atom}

      _shape, integer, _depth when is_integer(integer) ->
        :integer

      _shape, float, _depth when is_float(float) ->
        :float

      _shape, binary, _depth when is_binary(binary) ->
        {:binary, byte_size(binary)}

      _shape, [], _depth ->
        {:list, 0, nil}

      shape, [first | _] = list, depth ->
        length =
          try do
            length(list)
          catch
            # An improper list.
            :error, _ -> -1
          end

        {:list, length, shape.(shape, first, depth + 1)}

      shape, tuple, depth when is_tuple(tuple) and tuple_size(tuple) <= 8 ->
        {:tuple,
         :lists.map(fn e -> shape.(shape, e, depth + 1) end, :erlang.tuple_to_list(tuple))}

      _shape, tuple, _depth when is_tuple(tuple) ->
        {:tuple, tuple_size(tuple)}

      shape, %{__struct__: struct} = map, depth when is_atom(struct) ->
        fields = :maps.remove(:__struct__, map)
        keys = first_keys.(fields)

        {:struct, struct, map_size(fields),
         :lists.map(fn k -> {k, shape.(shape, :maps.get(k, fields), depth + 1)} end, keys)}

      shape, map, depth when is_map(map) ->
        keys = first_keys.(map)

        # Keys as they are (binaries cut to 64 bytes), other key terms as
        # their shape.
        key = fn
          k when is_atom(k) or is_integer(k) -> k
          k when is_binary(k) and byte_size(k) <= 64 -> k
          k when is_binary(k) -> :erlang.binary_part(k, 0, 64)
          k -> shape.(shape, k, 4)
        end

        {:map, map_size(map),
         :lists.map(fn k -> {key.(k), shape.(shape, :maps.get(k, map), depth + 1)} end, keys)}

      _shape, pid, _depth when is_pid(pid) ->
        :pid

      _shape, ref, _depth when is_reference(ref) ->
        :reference

      _shape, fun, _depth when is_function(fun) ->
        :function

      _shape, port, _depth when is_port(port) ->
        :port

      _shape, _other, _depth ->
        :other
    end

    # What a raised exception was: its struct or error atom, never its data.
    raised = fn
      {_class, %{__exception__: true, __struct__: struct}} -> struct
      {_class, reason} when is_atom(reason) -> reason
      {_class, reason} when tuple_size(reason) > 0 and is_atom(elem(reason, 0)) -> elem(reason, 0)
      {class, _reason} -> class
    end

    # -- The trace: what to enable in the session, what to keep ------------

    plan =
      case {spec, target} do
        {{:shapes, {modules, function, arity}}, _} ->
          loaded =
            for text <- modules,
                {:ok, module} <- [existing.(text)],
                :erlang.module_loaded(module),
                do: module

          case loaded do
            [] ->
              :not_loaded

            [module | _] ->
              # Tracing these would slow down nearly everything on the node.
              refused =
                :code.is_loaded(module) == {:file, :preloaded} or
                  :lists.member(:application.get_application(module), [
                    {:ok, :kernel},
                    {:ok, :stdlib},
                    {:ok, :elixir},
                    {:ok, :compiler}
                  ])

              fun =
                case existing.(function) do
                  {:ok, fun} ->
                    if :lists.member({fun, arity}, :erlang.get_module_info(module, :functions)),
                      do: fun

                  :none ->
                    nil
                end

              cond do
                refused ->
                  :refused

                fun == nil ->
                  :no_function

                true ->
                  enable = fn session ->
                    flag_all.(session, [:call, :monotonic_timestamp])

                    # A call event (with the arguments) and a return or
                    # exception event (with the result) per call.
                    :trace.function(
                      session,
                      {module, fun, arity},
                      [{:_, [], [{:return_trace}, {:exception_trace}]}],
                      [:local]
                    )

                    %{}
                  end

                  # A call's shape waits, per process, for its result (a
                  # stack: the function may call itself).
                  finish = fn pid, outcome, ts, known ->
                    {args, duration_us, known} =
                      case :maps.get({:calls, pid}, known, []) do
                        [{args, called} | rest] ->
                          {args, div(ts - called, 1_000), :maps.put({:calls, pid}, rest, known)}

                        [] ->
                          # Called before the trace started.
                          {nil, nil, known}
                      end

                    {id, known} = known_identity.(pid, known)
                    {{pid, args, outcome, duration_us, at.(ts), id}, known}
                  end

                  keep = fn
                    {:trace_ts, pid, :call, {_m, _f, args}, ts}, known ->
                      shapes = :lists.map(fn arg -> shape.(shape, arg, 0) end, args)
                      calls = :maps.get({:calls, pid}, known, [])
                      {nil, :maps.put({:calls, pid}, [{shapes, ts} | calls], known)}

                    {:trace_ts, pid, :return_from, _mfa, value, ts}, known ->
                      finish.(pid, {:returned, shape.(shape, value, 0)}, ts, known)

                    {:trace_ts, pid, :exception_from, _mfa, error, ts}, known ->
                      finish.(pid, {:raised, raised.(error)}, ts, known)

                    _other, known ->
                      {nil, known}
                  end

                  {enable, keep}
              end
          end

        {_spec, []} ->
          :not_found

        {{:messages_to, _}, [receiver | _]} ->
          # A message sent by registered name has the name as its receiver.
          names =
            case :erlang.process_info(receiver, :registered_name) do
              {:registered_name, name} when name != [] -> [{[name, :_], [], []}]
              _none -> []
            end

          enable = fn session ->
            :trace.send(session, [{[receiver, :_], [], []} | names], [])
            flag_all.(session, [:send, :monotonic_timestamp])
            %{}
          end

          # Senders are identified when their first message is read.
          keep = fn
            {:trace_ts, sender, :send, message, _to, ts}, known ->
              {id, known} = known_identity.(sender, known)
              {{sender, receiver, tag.(tag, message), at.(ts), id}, known}

            _other, known ->
              {nil, known}
          end

          {enable, keep}

        {{:exits, _}, [root | _]} ->
          name =
            case :erlang.process_info(root, :registered_name) do
              {:registered_name, name} -> name
              _gone -> []
            end

          # The target and every process it started (by $ancestors, which
          # proc_lib sets), plus every process they start from now on.
          flags = [:procs, :set_on_spawn, :monotonic_timestamp]

          # Processes are identified now, and new ones when they are
          # spawned: by the time they exit, they cannot be asked.
          enable = fn session ->
            pids =
              for pid <- :erlang.processes(),
                  pid != me,
                  {_, ancestors} <- [:erlang.process_info(pid, {:dictionary, :"$ancestors"})],
                  is_list(ancestors),
                  :lists.member(root, ancestors) or
                    (name != [] and :lists.member(name, ancestors)),
                  do: pid

            # A process may exit between the listing and its flagging.
            :lists.foreach(
              fn pid ->
                try do
                  :trace.process(session, pid, true, flags)
                catch
                  :error, _ -> 0
                end
              end,
              [root | pids]
            )

            :maps.from_list(:lists.map(fn pid -> {pid, identity.(pid)} end, [root | pids]))
          end

          keep = fn
            {:trace_ts, parent, :spawn, child, mfa, _ts}, known ->
              # Asked right away, it may still be in proc_lib's entry point,
              # or already gone: then how it was spawned says who it is, and
              # the spawning process who started it.
              {name, call, by} = identity.(child)

              call =
                case call do
                  {:proc_lib, _, _} -> spawned_as.(mfa)
                  nil -> spawned_as.(mfa)
                  call -> call
                end

              by = if by == nil, do: who.(parent), else: by
              {nil, :maps.put(child, {name, call, by}, known)}

            {:trace_ts, pid, :exit, reason, ts}, known ->
              {reason_class, where} = class.(reason)
              id = :maps.get(pid, known, {nil, nil, nil})
              {{pid, reason_class, where, at.(ts), id}, known}

            _other, known ->
              {nil, known}
          end

          {enable, keep}
      end

    # -- Collecting events, within the limits ------------------------------

    # Holds the session too, at maximum priority: a low-priority tracer may
    # not run for a while on a busy node, while events keep coming.
    watchdog = fn session ->
      :erlang.spawn(fn ->
        :erlang.process_flag(:priority, :max)
        ref = :erlang.monitor(:process, me)

        watch = fn watch ->
          receive do
            {:DOWN, ^ref, _, _, _} ->
              :ok

            :porthole_stop ->
              :ok
          after
            1 ->
              case :erlang.process_info(me, :message_queue_len) do
                {:message_queue_len, queued} when queued >= max_events ->
                  :trace.session_destroy(session)
                  send(me, :porthole_watchdog)

                _other ->
                  watch.(watch)
              end
          end
        end

        watch.(watch)
      end)
    end

    # Reads events until the window ends, the querier goes away or
    # max_events were produced (read + still queued). The window's end is
    # also checked while events keep coming (`after` only fires on an empty
    # mailbox), every 100 events.
    read = fn read, keep, window_end, rows, count, known ->
      left = max(0, window_end - :erlang.monotonic_time(:millisecond))

      receive do
        event when elem(event, 0) == :trace_ts ->
          # `case`, not `if`: evaluated, `if` costs an extra guard per event.
          {row, known} = keep.(event, known)

          rows =
            case row do
              nil -> rows
              row -> [row | rows]
            end

          {:message_queue_len, queued} = :erlang.process_info(me, :message_queue_len)

          case count + 1 + queued >= max_events do
            true ->
              {:events, rows, count + 1, known}

            false ->
              case rem(count, 100) == 0 and
                     :erlang.monotonic_time(:millisecond) >= window_end do
                true -> {:window, rows, count + 1, known}
                false -> read.(read, keep, window_end, rows, count + 1, known)
              end
          end

        :porthole_watchdog ->
          {:events, rows, count, known}

        {:DOWN, ^querier_ref, _, _, _} ->
          {:querier, rows, count, known}
      after
        left -> {:window, rows, count, known}
      end
    end

    # Events already produced when the session ended, up to max_events and
    # until `until`. The rest are left unread: the VM frees them when this
    # process exits.
    drain = fn
      _drain, _keep, _until, rows, count, _known when count >= max_events ->
        {rows, count, :all}

      drain, keep, until, rows, count, known ->
        receive do
          event when elem(event, 0) == :trace_ts ->
            {row, known} = keep.(event, known)

            rows =
              case row do
                nil -> rows
                row -> [row | rows]
              end

            # The clock is read every 100 events.
            case rem(count, 100) == 0 and :erlang.monotonic_time(:millisecond) > until do
              true -> {rows, count + 1, :deadline}
              false -> drain.(drain, keep, until, rows, count + 1, known)
            end
        after
          0 -> {rows, count, :all}
        end
    end

    case plan do
      status when is_atom(status) ->
        %{status: status}

      {enable, keep} ->
        session = :trace.session_create(:porthole, me, [])
        known = enable.(session)
        dog = watchdog.(session)
        # The window starts once the trace is set up (flagging every process
        # takes a while on a large node).
        window_end = :erlang.monotonic_time(:millisecond) + window_ms
        {stopped, rows, count, known} = read.(read, keep, window_end, [], 0, known)
        :trace.session_destroy(session)
        send(dog, :porthole_stop)
        elapsed_ms = div(:erlang.monotonic_time(:nanosecond) - started, 1_000_000)
        until = :erlang.monotonic_time(:millisecond) + read_ms
        {rows, count, read} = drain.(drain, keep, until, rows, count, known)
        rows = :lists.reverse(rows)

        %{
          status: :ok,
          rows: :lists.sublist(rows, max_rows),
          truncated: length(rows) > max_rows,
          stopped: stopped,
          events: count,
          read: read,
          elapsed_ms: elapsed_ms
        }
    end
  end

  @doc """
  Counts calls to a module's functions (or to one function) for
  `window_ms`, per process, with their running time (`call_time` in an OTP
  trace session: the VM keeps counters, no event is sent per call). At most
  `max_rows` rows. `modules` are names to try; names only resolve to atoms
  that already exist.

  Modules of OTP and Elixir themselves are refused: their functions run
  everywhere, and tracing them would slow down the whole node. The session
  ends with this process, at the end of the window or when `querier` goes
  away.
  """
  @spec trace_calls(pid(), pid(), tuple(), pos_integer(), pos_integer()) :: map()
  def trace_calls(_caller, querier, {modules, function, arity}, window_ms, max_rows) do
    started = :erlang.monotonic_time(:nanosecond)
    querier_ref = :erlang.monitor(:process, querier)

    existing = fn text ->
      try do
        {:ok, :erlang.binary_to_existing_atom(text, :utf8)}
      catch
        :error, _ -> :none
      end
    end

    loaded =
      for text <- modules,
          {:ok, module} <- [existing.(text)],
          :erlang.module_loaded(module),
          do: module

    case loaded do
      [] ->
        %{status: :not_loaded}

      [module | _] ->
        refused =
          :code.is_loaded(module) == {:file, :preloaded} or
            :lists.member(:application.get_application(module), [
              {:ok, :kernel},
              {:ok, :stdlib},
              {:ok, :elixir},
              {:ok, :compiler}
            ])

        functions =
          for {f, a} <- :erlang.get_module_info(module, :functions),
              function == nil or existing.(function) == {:ok, f},
              arity == nil or arity == a,
              do: {f, a}

        cond do
          refused ->
            %{status: :refused, module: module}

          functions == [] ->
            %{status: :no_function, module: module}

          true ->
            session = :trace.session_create(:porthole, self(), [])

            # Every process, one at a time from this low-priority process,
            # and those spawned from now on: :all would block the VM's
            # schedulers while it flags them (see trace/7).
            :trace.process(session, :new_processes, true, [:call])

            :lists.foreach(
              fn pid ->
                try do
                  :trace.process(session, pid, true, [:call])
                catch
                  :error, _ -> 0
                end
              end,
              :erlang.processes()
            )

            :lists.foreach(
              fn {f, a} -> :trace.function(session, {module, f, a}, true, [:call_time]) end,
              functions
            )

            stopped =
              receive do
                {:DOWN, ^querier_ref, _, _, _} -> :querier
              after
                window_ms -> :window
              end

            rows =
              for {f, a} <- functions,
                  {:call_time, counters} <- [:trace.info(session, {module, f, a}, :call_time)],
                  is_list(counters),
                  {pid, count, seconds, us} <- counters,
                  count > 0,
                  do: {pid, {module, f, a}, count, seconds * 1_000_000 + us}

            :trace.session_destroy(session)

            %{
              status: :ok,
              rows: :lists.sublist(rows, max_rows),
              truncated: length(rows) > max_rows,
              stopped: stopped,
              events: 0,
              read: :all,
              elapsed_ms: div(:erlang.monotonic_time(:nanosecond) - started, 1_000_000)
            }
        end
    end
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

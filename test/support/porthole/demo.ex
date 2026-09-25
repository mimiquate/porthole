defmodule Porthole.Demo do
  @moduledoc """
  A small supervision tree of deliberately misbehaving processes, one per
  eval question, for tests and for trying queries by hand:

      iex -S mix
      iex> Porthole.Demo.start_link()
      iex> Porthole.print("SELECT registered_name, message_queue_len FROM processes ORDER BY 2 DESC LIMIT 5")

  | Process                   | Misbehavior                                    | Eval |
  |---------------------------|------------------------------------------------|------|
  | `SlowServer` + callers    | serializes slow calls; callers queue up        | 1, 4 |
  | `Leaker`                  | accumulates data in its state forever          | 2    |
  | `FlappySupervisor`        | its `:crasher` child exits every few ms        | 3    |
  | `Sink` + `Flooder`        | `Sink` is stuck, its mailbox grows unbounded   | 4    |
  | `EtsGrower`               | inserts into an ETS table forever              | 5    |
  | `HotServer`               | busy loop burning reductions                   | 6    |
  | orphan (`:porthole_demo_orphan`) | unlinked, unmonitored, unsupervised     | 7    |
  | `SocketLeaker`            | opens UDP sockets and never closes them (≤ 200)| -    |
  | `DeadlockA` / `DeadlockB` | call each other and wait forever               | -    |

  All processes are registered under their module name (so only one demo
  tree can run at a time) and stop with the tree, except the orphan, which is
  killed explicitly on shutdown.

  ## Options

    * `:callers` - clients hammering `SlowServer` (default 10).
    * `:slow_ms` - time `SlowServer` spends per call (default 20).
    * `:crash_ms` - lifetime of the flapping child (default 20).
    * `:tick_ms` - interval of the flooder, leaker and ETS grower (default 10).
  """

  use Supervisor

  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts \\ []), do: Supervisor.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(opts) do
    tick = Keyword.get(opts, :tick_ms, 10)

    children = [
      {__MODULE__.SlowServer, Keyword.get(opts, :slow_ms, 20)},
      {__MODULE__.Callers, Keyword.get(opts, :callers, 10)},
      {__MODULE__.Leaker, tick},
      {__MODULE__.FlappySupervisor, Keyword.get(opts, :crash_ms, 20)},
      __MODULE__.Sink,
      {__MODULE__.Flooder, tick},
      {__MODULE__.EtsGrower, tick},
      __MODULE__.HotServer,
      __MODULE__.OrphanMaker,
      {__MODULE__.SocketLeaker, tick},
      # Blocked forever, so they cannot stop gracefully.
      Supervisor.child_spec({__MODULE__.Deadlock, __MODULE__.DeadlockA},
        id: :deadlock_a,
        shutdown: :brutal_kill
      ),
      Supervisor.child_spec({__MODULE__.Deadlock, __MODULE__.DeadlockB},
        id: :deadlock_b,
        shutdown: :brutal_kill
      )
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end

  defmodule SlowServer do
    @moduledoc false
    use GenServer

    def start_link(slow_ms), do: GenServer.start_link(__MODULE__, slow_ms, name: __MODULE__)

    @impl true
    def init(slow_ms), do: {:ok, slow_ms}

    @impl true
    def handle_call(:work, _from, slow_ms) do
      Process.sleep(slow_ms)
      {:reply, :ok, slow_ms}
    end
  end

  defmodule Callers do
    @moduledoc false
    # Supervises N looping clients of SlowServer.
    use Supervisor

    def start_link(count), do: Supervisor.start_link(__MODULE__, count, name: __MODULE__)

    @impl true
    def init(count) do
      children =
        for i <- 1..count do
          Supervisor.child_spec({Task, &call_forever/0}, id: {:caller, i}, restart: :permanent)
        end

      Supervisor.init(children, strategy: :one_for_one)
    end

    defp call_forever do
      GenServer.call(SlowServer, :work, :infinity)
      call_forever()
    end
  end

  defmodule Leaker do
    @moduledoc false
    use GenServer

    def start_link(tick), do: GenServer.start_link(__MODULE__, tick, name: __MODULE__)

    @impl true
    def init(tick) do
      :timer.send_interval(tick, :leak)
      {:ok, []}
    end

    @impl true
    def handle_info(:leak, leaked) do
      {:noreply, [{Enum.to_list(1..100), :binary.copy("x", 1024)} | leaked]}
    end
  end

  defmodule FlappySupervisor do
    @moduledoc false
    use Supervisor

    def start_link(crash_ms), do: Supervisor.start_link(__MODULE__, crash_ms, name: __MODULE__)

    @impl true
    def init(crash_ms) do
      children = [
        Supervisor.child_spec({Porthole.Demo.Crasher, crash_ms}, id: :crasher),
        Supervisor.child_spec({Agent, fn -> :stable end}, id: :stable)
      ]

      # A restart intensity high enough to flap forever instead of giving up.
      Supervisor.init(children, strategy: :one_for_one, max_restarts: 1_000_000, max_seconds: 1)
    end
  end

  defmodule Crasher do
    @moduledoc false
    # Stops with :shutdown so the restart loop does not flood the logs.
    use GenServer

    def start_link(crash_ms), do: GenServer.start_link(__MODULE__, crash_ms)

    @impl true
    def init(crash_ms) do
      Process.send_after(self(), :crash, crash_ms)
      {:ok, nil}
    end

    @impl true
    def handle_info(:crash, state), do: {:stop, :shutdown, state}
  end

  defmodule Sink do
    @moduledoc false
    # Blocks forever in a callback, so its mailbox only grows.
    use GenServer

    def start_link(_arg), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

    @impl true
    def init(nil), do: {:ok, nil, {:continue, :block}}

    @impl true
    def handle_continue(:block, state) do
      receive do
        :unblock -> {:noreply, state}
      end
    end
  end

  defmodule Flooder do
    @moduledoc false
    use GenServer

    def start_link(tick), do: GenServer.start_link(__MODULE__, tick, name: __MODULE__)

    @impl true
    def init(tick) do
      :timer.send_interval(tick, :flood)
      {:ok, nil}
    end

    @impl true
    def handle_info(:flood, state) do
      for i <- 1..50, do: send(Sink, {:event, i})
      {:noreply, state}
    end
  end

  defmodule EtsGrower do
    @moduledoc false
    use GenServer

    @table :porthole_demo_growing

    def start_link(tick), do: GenServer.start_link(__MODULE__, tick, name: __MODULE__)

    @impl true
    def init(tick) do
      table = :ets.new(@table, [:named_table, :public, :set])
      :timer.send_interval(tick, :grow)
      {:ok, {table, 0}}
    end

    @impl true
    def handle_info(:grow, {table, n}) do
      :ets.insert(table, for(i <- n..(n + 99), do: {i, :payload}))
      {:noreply, {table, n + 100}}
    end
  end

  defmodule HotServer do
    @moduledoc false
    use GenServer

    def start_link(_arg), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

    @impl true
    def init(nil) do
      send(self(), :spin)
      {:ok, 0}
    end

    @impl true
    def handle_info(:spin, acc) do
      send(self(), :spin)
      {:noreply, rem(acc + Enum.sum(1..1_000), 1_000_000)}
    end
  end

  defmodule SocketLeaker do
    @moduledoc false
    use GenServer

    @max 200

    def start_link(tick), do: GenServer.start_link(__MODULE__, tick, name: __MODULE__)

    @impl true
    def init(tick) do
      :timer.send_interval(tick, :leak)
      {:ok, []}
    end

    @impl true
    def handle_info(:leak, sockets) when length(sockets) >= @max, do: {:noreply, sockets}

    def handle_info(:leak, sockets) do
      {:ok, socket} = :gen_udp.open(0)
      {:noreply, [socket | sockets]}
    end
  end

  defmodule Deadlock do
    @moduledoc false
    # DeadlockA calls DeadlockB, which calls DeadlockA: both wait forever.
    use GenServer

    def start_link(name), do: GenServer.start_link(__MODULE__, name, name: name)

    @impl true
    def init(name) do
      Process.send_after(self(), :call_peer, 50)
      {:ok, name}
    end

    @impl true
    def handle_info(:call_peer, name) do
      peer =
        if name == Porthole.Demo.DeadlockA,
          do: Porthole.Demo.DeadlockB,
          else: Porthole.Demo.DeadlockA

      GenServer.call(peer, :ping, :infinity)
      {:noreply, name}
    end

    @impl true
    def handle_call(:ping, _from, name), do: {:reply, :pong, name}
  end

  defmodule OrphanMaker do
    @moduledoc false
    # Spawns a process with no links and no monitors, outside supervision.
    use GenServer

    @name :porthole_demo_orphan

    def start_link(_arg), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

    @impl true
    def init(nil) do
      Process.flag(:trap_exit, true)

      orphan =
        spawn(fn ->
          Process.register(self(), @name)
          Process.sleep(:infinity)
        end)

      {:ok, orphan}
    end

    @impl true
    def terminate(_reason, orphan), do: Process.exit(orphan, :kill)
  end
end

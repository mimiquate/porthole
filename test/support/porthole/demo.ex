defmodule Porthole.Demo do
  @moduledoc """
  A small online-shop application with deliberately planted problems, used
  to exercise the eval set and to test agents.

  The processes have ordinary names, and the tree runs as a real OTP
  application (`:shop`), so nothing visible at runtime gives the problems
  away: an agent has to *diagnose* them. The answer key is below, and only
  here:

  | Process                          | Planted problem                                  | Eval |
  |----------------------------------|--------------------------------------------------|------|
  | `Shop.Pricing`                   | serializes slow calls; checkout workers queue up | 1, 4 |
  | `Shop.Checkout.Worker` (×10)     | the callers stuck behind `Shop.Pricing`          | 1    |
  | `Shop.Analytics`                 | keeps every event (and its binary) forever       | 2    |
  | `Shop.Payments.Supervisor`       | its `Shop.Payments.Gateway` child crash-loops    | 3    |
  | `Shop.Notifications`             | stuck; its mailbox grows without bound           | 4    |
  | `Shop.Orders.EventRelay`         | the sender flooding `Shop.Notifications`         | 4    |
  | `Shop.Search.Indexer`            | ETS table `shop_search_index` grows forever      | 5    |
  | `Shop.Inventory.Sync`            | busy loop burning CPU                            | 6    |
  | `:shop_import_watcher`           | unlinked, unmonitored, unsupervised (orphan)     | 7    |
  | `Shop.Metrics.Reporter`          | opens UDP sockets, never closes them (≤ 200)     | -    |
  | `Shop.Cart` / `Shop.Promotions`  | call each other: deadlocked                      | -    |

  Start it with `start/1` (e.g. `iex -S mix run -e 'Porthole.Demo.start()'`)
  and stop it with `stop/0`. It grows without bound by design: don't leave it
  running.

  ## Options

    * `:checkout_workers` - clients calling `Shop.Pricing` (default 10).
    * `:pricing_ms` - time `Shop.Pricing` spends per call (default 20).
    * `:gateway_ms` - lifetime of the crashing gateway (default 20).
    * `:tick_ms` - pace of the relay, analytics, indexer and reporter
      (default 10).
  """

  @app :shop

  @doc "Loads and starts the `:shop` application (restarting it if running)."
  @spec start(keyword()) :: :ok
  def start(opts \\ []) do
    stop()

    :ok =
      :application.load(
        {:application, @app,
         [
           description: ~c"Online shop",
           vsn: ~c"1.4.2",
           modules: [],
           registered: [],
           applications: [:kernel, :stdlib, :elixir],
           mod: {Shop.Application, opts}
         ]}
      )

    :ok = Application.start(@app)
  end

  @doc "Stops and unloads the `:shop` application."
  @spec stop() :: :ok
  def stop do
    Application.stop(@app)
    Application.unload(@app)
    :ok
  end
end

defmodule Shop.Application do
  @moduledoc false
  use Application

  @impl true
  def start(_type, opts) do
    tick = Keyword.get(opts, :tick_ms, 10)

    children = [
      {Shop.Pricing, Keyword.get(opts, :pricing_ms, 20)},
      {Shop.Checkout.Supervisor, Keyword.get(opts, :checkout_workers, 10)},
      {Shop.Analytics, tick},
      {Shop.Payments.Supervisor, Keyword.get(opts, :gateway_ms, 20)},
      Shop.Notifications,
      {Shop.Orders.EventRelay, tick},
      {Shop.Search.Indexer, tick},
      Shop.Inventory.Sync,
      Shop.Importer,
      {Shop.Metrics.Reporter, tick},
      # Deadlocked, so they cannot stop gracefully.
      Supervisor.child_spec(Shop.Cart, shutdown: :brutal_kill),
      Supervisor.child_spec(Shop.Promotions, shutdown: :brutal_kill)
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: Shop.Supervisor)
  end
end

defmodule Shop.Pricing do
  @moduledoc false
  use GenServer

  def start_link(ms), do: GenServer.start_link(__MODULE__, ms, name: __MODULE__)
  def quote(sku), do: GenServer.call(__MODULE__, {:quote, sku}, :infinity)

  @impl true
  def init(ms), do: {:ok, ms}

  @impl true
  def handle_call({:quote, _sku}, _from, ms) do
    Process.sleep(ms)
    {:reply, {:ok, 1999}, ms}
  end
end

defmodule Shop.Checkout.Supervisor do
  @moduledoc false
  use Supervisor

  def start_link(count), do: Supervisor.start_link(__MODULE__, count, name: __MODULE__)

  @impl true
  def init(count) do
    children =
      for i <- 1..count do
        Supervisor.child_spec({Task, &Shop.Checkout.Worker.run/0},
          id: {Shop.Checkout.Worker, i},
          restart: :permanent
        )
      end

    Supervisor.init(children, strategy: :one_for_one)
  end
end

defmodule Shop.Checkout.Worker do
  @moduledoc false
  def run do
    Shop.Pricing.quote("sku-#{System.unique_integer([:positive])}")
    run()
  end
end

defmodule Shop.Analytics do
  @moduledoc false
  use GenServer

  def start_link(tick), do: GenServer.start_link(__MODULE__, tick, name: __MODULE__)

  @impl true
  def init(tick) do
    :timer.send_interval(tick, :collect)
    {:ok, []}
  end

  @impl true
  def handle_info(:collect, events) do
    {:noreply, [{Enum.to_list(1..100), :binary.copy("x", 1024)} | events]}
  end
end

defmodule Shop.Payments.Supervisor do
  @moduledoc false
  use Supervisor

  def start_link(ms), do: Supervisor.start_link(__MODULE__, ms, name: __MODULE__)

  @impl true
  def init(ms) do
    children = [
      {Shop.Payments.Gateway, ms},
      Supervisor.child_spec({Agent, fn -> %{} end}, id: Shop.Payments.Ledger)
    ]

    # High enough to crash-loop forever instead of giving up.
    Supervisor.init(children, strategy: :one_for_one, max_restarts: 1_000_000, max_seconds: 1)
  end
end

defmodule Shop.Payments.Gateway do
  @moduledoc false
  # Stops with :shutdown so the loop does not flood the logs.
  use GenServer

  def start_link(ms), do: GenServer.start_link(__MODULE__, ms)

  @impl true
  def init(ms) do
    Process.send_after(self(), :connect, ms)
    {:ok, nil}
  end

  @impl true
  def handle_info(:connect, state), do: {:stop, :shutdown, state}
end

defmodule Shop.Notifications do
  @moduledoc false
  use GenServer

  def start_link(_arg), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  @impl true
  def init(nil), do: {:ok, nil, {:continue, :connect_provider}}

  # Waits for a provider acknowledgement that never comes.
  @impl true
  def handle_continue(:connect_provider, state) do
    receive do
      :provider_ready -> {:noreply, state}
    end
  end
end

defmodule Shop.Orders.EventRelay do
  @moduledoc false
  use GenServer

  def start_link(tick), do: GenServer.start_link(__MODULE__, tick, name: __MODULE__)

  @impl true
  def init(tick) do
    :timer.send_interval(tick, :relay)
    {:ok, nil}
  end

  @impl true
  def handle_info(:relay, state) do
    for i <- 1..50, do: send(Shop.Notifications, {:order_event, i})
    {:noreply, state}
  end
end

defmodule Shop.Search.Indexer do
  @moduledoc false
  use GenServer

  def start_link(tick), do: GenServer.start_link(__MODULE__, tick, name: __MODULE__)

  @impl true
  def init(tick) do
    table = :ets.new(:shop_search_index, [:named_table, :public, :set])
    :timer.send_interval(tick, :index)
    {:ok, {table, 0}}
  end

  @impl true
  def handle_info(:index, {table, n}) do
    :ets.insert(table, for(i <- n..(n + 99), do: {i, :document}))
    {:noreply, {table, n + 100}}
  end
end

defmodule Shop.Inventory.Sync do
  @moduledoc false
  use GenServer

  def start_link(_arg), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  @impl true
  def init(nil) do
    send(self(), :sync)
    {:ok, 0}
  end

  @impl true
  def handle_info(:sync, acc) do
    send(self(), :sync)
    {:noreply, rem(acc + Enum.sum(1..1_000), 1_000_000)}
  end
end

defmodule Shop.Importer do
  @moduledoc false
  # Spawns a watcher with no links and no monitors, outside supervision.
  use GenServer

  def start_link(_arg), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  @impl true
  def init(nil) do
    Process.flag(:trap_exit, true)

    watcher =
      spawn(fn ->
        Process.register(self(), :shop_import_watcher)
        Process.sleep(:infinity)
      end)

    {:ok, watcher}
  end

  @impl true
  def terminate(_reason, watcher), do: Process.exit(watcher, :kill)
end

defmodule Shop.Metrics.Reporter do
  @moduledoc false
  use GenServer

  @max 200

  def start_link(tick), do: GenServer.start_link(__MODULE__, tick, name: __MODULE__)

  @impl true
  def init(tick) do
    :timer.send_interval(tick, :report)
    {:ok, []}
  end

  @impl true
  def handle_info(:report, sockets) when length(sockets) >= @max, do: {:noreply, sockets}

  def handle_info(:report, sockets) do
    {:ok, socket} = :gen_udp.open(0)
    {:noreply, [socket | sockets]}
  end
end

defmodule Shop.Cart do
  @moduledoc false
  use GenServer

  def start_link(_arg), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  @impl true
  def init(nil) do
    Process.send_after(self(), :refresh_discounts, 50)
    {:ok, nil}
  end

  @impl true
  def handle_info(:refresh_discounts, state) do
    GenServer.call(Shop.Promotions, :active, :infinity)
    {:noreply, state}
  end

  @impl true
  def handle_call(:contents, _from, state), do: {:reply, [], state}
end

defmodule Shop.Promotions do
  @moduledoc false
  use GenServer

  def start_link(_arg), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  @impl true
  def init(nil) do
    Process.send_after(self(), :recompute, 50)
    {:ok, nil}
  end

  @impl true
  def handle_info(:recompute, state) do
    GenServer.call(Shop.Cart, :contents, :infinity)
    {:noreply, state}
  end

  @impl true
  def handle_call(:active, _from, state), do: {:reply, [], state}
end

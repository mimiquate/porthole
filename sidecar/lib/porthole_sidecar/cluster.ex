defmodule PortholeSidecar.Cluster do
  @moduledoc """
  Keeps the sidecar connected to the nodes it observes.

  Every few seconds it resolves the targets (seed nodes, their peers when
  following peers, and DNS discovery), connects to any it is not connected
  to, and remembers which ones are up. `nodes/0` returns them; queries call
  it every time, so nodes that join or leave the cluster are picked up
  without a restart.
  """

  use GenServer
  require Logger

  @interval 5_000

  @doc false
  def start_link(config), do: GenServer.start_link(__MODULE__, config, name: __MODULE__)

  @doc "The observed nodes currently connected."
  @spec nodes() :: [node()]
  def nodes, do: GenServer.call(__MODULE__, :nodes)

  @impl true
  def init(config) do
    {:ok, %{config: config, nodes: []}, {:continue, :refresh}}
  end

  @impl true
  def handle_continue(:refresh, state), do: {:noreply, refresh(state)}

  @impl true
  def handle_info(:refresh, state), do: {:noreply, refresh(state)}

  @impl true
  def handle_call(:nodes, _from, state), do: {:reply, state.nodes, state}

  defp refresh(state) do
    Process.send_after(self(), :refresh, @interval)
    targets = targets(state.config)
    connected = Enum.filter(targets, &(&1 in Node.list(:connected) or Node.connect(&1) == true))

    if connected != state.nodes do
      Logger.info("Porthole sidecar observing: #{Enum.join(connected, ", ")}")
      missing = targets -- connected

      if missing != [],
        do: Logger.warning("Porthole sidecar cannot reach: #{Enum.join(missing, ", ")}")
    end

    %{state | nodes: connected}
  end

  defp targets(config) do
    discovered = discover(config.discovery)
    seeds = Enum.uniq(config.seeds ++ discovered)
    peers = if config.follow_peers, do: Enum.flat_map(seeds, &peers/1), else: []
    Enum.uniq(seeds ++ peers) -- [node()]
  end

  defp discover(nil), do: []

  defp discover({:dns, name, basename}) do
    name = String.to_charlist(name)
    ips = :inet_res.lookup(name, :in, :a) ++ :inet_res.lookup(name, :in, :aaaa)
    for ip <- ips, do: :"#{basename}@#{:inet.ntoa(ip)}"
  end

  defp peers(seed) do
    if Node.connect(seed) == true, do: :erpc.call(seed, Node, :list, [], 2_000), else: []
  catch
    _, _ -> []
  end
end

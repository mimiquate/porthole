defmodule PortholeSidecar.Cluster do
  @moduledoc """
  Keeps the sidecar connected to the nodes it observes.

  Every few seconds it works out which nodes to observe, without needing to
  know their names in advance:

    1. **Hosts** come from DNS (`DNS_CLUSTER_QUERY` / `PORTHOLE_DISCOVERY`,
       IPv4 addresses if there are any, otherwise IPv6) and from host entries
       in `PORTHOLE_NODES`.
    2. **Nodes on each host** come from that host's Erlang port mapper (epmd),
       which lists the node names registered there. Remote consoles
       (`rem-*`), the sidecar's own name and, with `PORTHOLE_NODE_PREFIX`,
       non-matching names are skipped.
    3. **Peers**: with `PORTHOLE_FOLLOW_PEERS` (the default), every node the
       found nodes are connected to is observed too.

  Full node names in `PORTHOLE_NODES` are used as they are. `nodes/0`
  returns the connected ones; queries call it every time, so nodes that join
  or leave are picked up without a restart.
  """

  use GenServer
  require Logger

  @interval 5_000
  # A host that does not answer would otherwise block discovery for over a
  # minute (the TCP connect timeout).
  @lookup_timeout 2_000

  @doc false
  def start_link(config), do: GenServer.start_link(__MODULE__, config, name: __MODULE__)

  @doc "The observed nodes currently connected."
  @spec nodes() :: [node()]
  def nodes, do: GenServer.call(__MODULE__, :nodes)

  @doc false
  # Exposed for tests: resolves the targets once, without connecting.
  @spec targets(PortholeSidecar.Config.t()) :: [node()]
  def targets(config) do
    hosts = Enum.uniq(config.hosts ++ Enum.flat_map(config.dns, &resolve/1))
    found = Enum.uniq(config.nodes ++ Enum.flat_map(hosts, &nodes_on(&1, config.prefix)))
    peers = if config.follow_peers, do: Enum.flat_map(found, &peers/1), else: []
    Enum.uniq(found ++ peers) -- [node()]
  end

  @impl true
  def init(config),
    do:
      {:ok, %{config: config, nodes: [], missing: [], warned_empty: false}, {:continue, :refresh}}

  @impl true
  def handle_continue(:refresh, state), do: {:noreply, refresh(state)}

  @impl true
  def handle_info(:refresh, state), do: {:noreply, refresh(state)}

  @impl true
  def handle_call(:nodes, _from, state), do: {:reply, state.nodes, state}

  # Logs whenever what the sidecar observes, or fails to reach, changes: not
  # every 5 seconds, but never silently either.
  defp refresh(state) do
    Process.send_after(self(), :refresh, @interval)
    targets = targets(state.config)
    connected = Enum.filter(targets, &(&1 in Node.list(:connected) or Node.connect(&1) == true))
    missing = targets -- connected

    if connected != state.nodes and connected != [] do
      Logger.info("Porthole sidecar observing: #{Enum.join(connected, ", ")}")
    end

    # Erlang gives no reason for a refused connection, and a cookie that
    # differs from the app's is by far the most common one.
    if missing != state.missing and missing != [] do
      Logger.warning(
        "Porthole sidecar cannot connect to: #{Enum.join(missing, ", ")}. " <>
          "Check that RELEASE_COOKIE is the same secret as the app's, and that the node's " <>
          "distribution port is reachable (mix porthole.doctor explains more)"
      )
    end

    if targets == [] and not state.warned_empty do
      Logger.warning(
        "Porthole sidecar found no nodes to observe: check DNS_CLUSTER_QUERY / PORTHOLE_NODES, " <>
          "and that epmd (port 4369) on those hosts is reachable from here"
      )
    end

    %{state | nodes: connected, missing: missing, warned_empty: targets == []}
  end

  # The system resolver (hosts file and DNS). IPv4 if any, otherwise IPv6.
  defp resolve(name) do
    name = String.to_charlist(name)

    case :inet.getaddrs(name, :inet) do
      {:ok, [_ | _] = ips} ->
        Enum.map(ips, &(&1 |> :inet.ntoa() |> to_string()))

      _ ->
        case :inet.getaddrs(name, :inet6) do
          {:ok, ips} -> Enum.map(ips, &(&1 |> :inet.ntoa() |> to_string()))
          _ -> []
        end
    end
  end

  defp nodes_on(host, prefix) do
    own = node() |> Atom.to_string() |> String.split("@") |> hd()

    task = Task.async(fn -> :erl_epmd.names(String.to_charlist(host)) end)

    names =
      case Task.yield(task, @lookup_timeout) || Task.shutdown(task, :brutal_kill) do
        {:ok, {:ok, names}} -> Enum.map(names, &(&1 |> elem(0) |> to_string()))
        _ -> []
      end

    for name <- names,
        name != own,
        not String.starts_with?(name, "rem-"),
        prefix == nil or String.starts_with?(name, prefix),
        do: :"#{name}@#{host}"
  end

  defp peers(node) do
    if Node.connect(node) == true,
      do: :erpc.call(node, Node, :list, [], @lookup_timeout),
      else: []
  catch
    _, _ -> []
  end
end

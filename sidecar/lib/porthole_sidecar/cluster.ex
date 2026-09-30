defmodule PortholeSidecar.Cluster do
  @moduledoc """
  Keeps the sidecar connected to the nodes it observes.

  Every few seconds it works out which nodes to observe, without needing to
  know their names in advance:

    1. **Hosts** come from DNS (`DNS_CLUSTER_QUERY` / `PORTHOLE_DISCOVERY`),
       preferring the address family of the sidecar's own distribution (IPv6
       with `-proto_dist inet6_tcp`), and from host entries in
       `PORTHOLE_NODES`.
    2. **Nodes on each host** come from that host's Erlang port mapper (epmd),
       which lists the node names registered there. Remote consoles
       (`rem-*`), `rpc` calls (`rpc-*`), the sidecar's own name and, with
       `PORTHOLE_NODE_PREFIX`,
       non-matching names are skipped.
    3. **Peers**: with `PORTHOLE_FOLLOW_PEERS` (the default), every node the
       found nodes are connected to is observed too.

  Full node names in `PORTHOLE_NODES` are used as they are. `nodes/0`
  returns the connected ones; queries call it every time, so nodes that join
  or leave are picked up without a restart.

  ## IPv6 spellings

  A node's name must be matched exactly, and the same IPv6 address can be
  written in more than one way: a node started as
  `app@fdaa:0:0:a7b:ab3:2e2b:fa7c:2` (e.g. from `FLY_PRIVATE_IP`) is the
  address Erlang writes as `fdaa::a7b:ab3:2e2b:fa7c:2`. For IPv6 hosts the
  sidecar therefore tries both the compressed and the uncompressed spelling,
  and keeps whichever connects.
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
  # Exposed for tests: resolves the targets once, without connecting. Each
  # target is one node, as the list of spellings its name may have.
  @spec targets(PortholeSidecar.Config.t()) :: [[node(), ...]]
  def targets(config) do
    hosts = Enum.uniq(config.hosts ++ Enum.flat_map(config.dns, &resolve/1))
    found = Enum.map(config.nodes, &[&1]) ++ Enum.flat_map(hosts, &nodes_on(&1, config.prefix))
    # Peers are reported by their exact names, by nodes already connected.
    peers = if config.follow_peers, do: Enum.flat_map(found, &peers/1), else: []

    (found ++ Enum.map(peers, &[&1]))
    |> Enum.uniq()
    |> Enum.reject(&(node() in &1))
  end

  @doc false
  # The ways a host can appear in a node name: IPv6 addresses compressed
  # (`fdaa::1`) and uncompressed (`fdaa:0:0:0:0:0:0:1`); anything else as is.
  @spec host_spellings(String.t()) :: [String.t(), ...]
  def host_spellings(host) do
    case :inet.parse_ipv6strict_address(String.to_charlist(host)) do
      {:ok, ip} ->
        compressed = ip |> :inet.ntoa() |> to_string()

        uncompressed =
          ip
          |> Tuple.to_list()
          |> Enum.map_join(":", &Integer.to_string(&1, 16))
          |> String.downcase()

        Enum.uniq([host, compressed, uncompressed])

      {:error, _} ->
        [host]
    end
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

    reached =
      Enum.map(targets, fn spellings -> {spellings, Enum.find(spellings, &connected?/1)} end)

    # Sorted: DNS answers in rotating order, which is not a change.
    connected = for({_, node} <- reached, node, do: node) |> Enum.uniq() |> Enum.sort()
    missing = for({[name | _], nil} <- reached, do: name) |> Enum.sort()

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

  defp connected?(node), do: node in Node.list(:connected) or Node.connect(node) == true

  # The system resolver (hosts file and DNS), preferring the address family
  # the sidecar's own distribution uses (IPv6 with -proto_dist inet6_tcp, as
  # on Fly.io): nodes can only be reached over the family they listen on.
  defp resolve(name) do
    name = String.to_charlist(name)

    Enum.find_value(families(), [], fn family ->
      case :inet.getaddrs(name, family) do
        {:ok, [_ | _] = ips} -> Enum.map(ips, &(&1 |> :inet.ntoa() |> to_string()))
        _ -> nil
      end
    end)
  end

  defp families do
    case :init.get_argument(:proto_dist) do
      {:ok, [[~c"inet6" ++ _]]} -> [:inet6, :inet]
      _ -> [:inet, :inet6]
    end
  end

  defp nodes_on(host, prefix) do
    own = node() |> Atom.to_string() |> String.split("@") |> hd()

    # Addresses must be passed parsed: given as a string, an IPv6 address is
    # taken for a hostname to resolve and fails (nxdomain).
    address =
      case :inet.parse_address(String.to_charlist(host)) do
        {:ok, ip} -> ip
        {:error, _} -> String.to_charlist(host)
      end

    task = Task.async(fn -> :erl_epmd.names(address) end)

    names =
      case Task.yield(task, @lookup_timeout) || Task.shutdown(task, :brutal_kill) do
        {:ok, {:ok, names}} -> Enum.map(names, &(&1 |> elem(0) |> to_string()))
        _ -> []
      end

    for name <- names,
        name != own,
        # Short-lived tool nodes: release remote consoles and rpc/eval calls.
        not String.starts_with?(name, ["rem-", "rpc-"]),
        prefix == nil or String.starts_with?(name, prefix),
        do: for(spelling <- host_spellings(host), do: :"#{name}@#{spelling}")
  end

  defp peers(spellings) do
    case Enum.find(spellings, &connected?/1) do
      nil -> []
      node -> :erpc.call(node, Node, :list, [], @lookup_timeout)
    end
  catch
    _, _ -> []
  end
end

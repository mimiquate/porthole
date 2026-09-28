defmodule PortholeSidecar.ClusterTest do
  @moduledoc "Discovery against real nodes: the sidecar is told where, not who."
  use ExUnit.Case, async: false

  alias PortholeSidecar.Cluster

  setup_all do
    System.cmd("epmd", ["-daemon"])

    {:ok, _} =
      :net_kernel.start(:"sidecar_test@127.0.0.1", %{name_domain: :longnames, hidden: true})

    peers =
      for name <- [:shop, :"rem-1a2b-shop", :other_app] do
        {:ok, pid, node} = :peer.start(%{name: name, host: ~c"127.0.0.1", longnames: true})
        {pid, node}
      end

    on_exit(fn -> for {pid, _} <- peers, do: :peer.stop(pid) end)
    :ok
  end

  defp config(overrides) do
    Map.merge(%{nodes: [], hosts: [], dns: [], prefix: nil, follow_peers: false}, overrides)
  end

  test "finds the nodes on a host from its port mapper, skipping remote consoles and itself" do
    targets = Cluster.targets(config(%{hosts: ["127.0.0.1"]}))

    assert :"shop@127.0.0.1" in targets
    assert :"other_app@127.0.0.1" in targets
    refute :"rem-1a2b-shop@127.0.0.1" in targets
    refute node() in targets
  end

  test "resolves hosts through DNS (the system resolver, hosts file included)" do
    assert :"shop@127.0.0.1" in Cluster.targets(config(%{dns: ["localhost"]}))
  end

  test "a prefix keeps only the app's nodes" do
    targets = Cluster.targets(config(%{hosts: ["127.0.0.1"], prefix: "shop"}))
    assert :"shop@127.0.0.1" in targets
    refute :"other_app@127.0.0.1" in targets
  end

  test "full node names are used as given, and unknown hosts are skipped quickly" do
    {us, targets} =
      :timer.tc(fn ->
        Cluster.targets(config(%{nodes: [:"shop@127.0.0.1"], hosts: ["10.255.255.1"]}))
      end)

    assert targets == [:"shop@127.0.0.1"]
    # Without a timeout, an unreachable host blocks for over a minute.
    assert us < 5_000_000
  end
end

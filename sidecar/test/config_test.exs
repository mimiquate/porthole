defmodule PortholeSidecar.ConfigTest do
  use ExUnit.Case, async: true

  alias PortholeSidecar.Config

  @hash String.duplicate("ab", 32)
  @tokens %{"PORTHOLE_TOKENS" => "oncall:#{@hash}"}

  test "the common case: the app's own DNS_CLUSTER_QUERY" do
    config = Config.from_env!(Map.put(@tokens, "DNS_CLUSTER_QUERY", "shop.internal"))

    assert config.dns == ["shop.internal"]
    assert config.tokens == [[id: "oncall", sha256: @hash]]

    assert {config.port, config.ip, config.follow_peers, config.tls} ==
             {4040, {0, 0, 0, 0}, true, []}
  end

  test "PORTHOLE_NODES takes hosts and full node names" do
    config =
      Config.from_env!(Map.put(@tokens, "PORTHOLE_NODES", "10.0.1.12, shop@10.0.1.13, db-host"))

    assert config.hosts == ["10.0.1.12", "db-host"]
    assert config.nodes == [:"shop@10.0.1.13"]
    assert config.dns == []
  end

  test "PORTHOLE_DISCOVERY wins over DNS_CLUSTER_QUERY, and a node prefix filters names" do
    config =
      Config.from_env!(
        Map.merge(@tokens, %{
          "DNS_CLUSTER_QUERY" => "ignored.internal",
          # The old dns:<name>:<basename> form still works; the basename is not needed.
          "PORTHOLE_DISCOVERY" => "dns:my-app.default.svc.cluster.local:my_app",
          "PORTHOLE_NODE_PREFIX" => "my_app"
        })
      )

    assert config.dns == ["my-app.default.svc.cluster.local"]
    assert config.prefix == "my_app"
  end

  test "reads port, bind, TLS and peer following" do
    config =
      Config.from_env!(
        Map.merge(@tokens, %{
          "PORTHOLE_NODES" => "10.0.1.12",
          "PORTHOLE_FOLLOW_PEERS" => "false",
          "PORTHOLE_PORT" => "8443",
          "PORTHOLE_BIND" => "10.0.0.5",
          "PORTHOLE_CERTFILE" => "/tls/cert.pem",
          "PORTHOLE_KEYFILE" => "/tls/key.pem"
        })
      )

    refute config.follow_peers
    assert {config.port, config.ip} == {8443, {10, 0, 0, 5}}
    assert config.tls == [certfile: "/tls/cert.pem", keyfile: "/tls/key.pem"]
  end

  test "reads tokens with policies and the environment policy from a config file" do
    path =
      Path.join(System.tmp_dir!(), "porthole_sidecar_#{System.unique_integer([:positive])}.exs")

    File.write!(path, """
    import Config
    config :porthole, :tokens, [[id: "ci", sha256: "#{@hash}", policy: [queries_per_minute: 10]]]
    config :porthole, :policy, max_result_rows: 50
    """)

    on_exit(fn ->
      File.rm(path)
      Application.delete_env(:porthole, :policy)
    end)

    config = Config.from_env!(%{"PORTHOLE_CONFIG" => path, "PORTHOLE_NODES" => "10.0.1.12"})
    assert [[id: "ci", sha256: _, policy: [queries_per_minute: 10]]] = config.tokens
    assert Application.get_env(:porthole, :policy) == [max_result_rows: 50]
  end

  test "explains what is missing or wrong" do
    for {env, message} <- [
          {%{"PORTHOLE_NODES" => "10.0.1.12"}, ~r/PORTHOLE_TOKENS/},
          {@tokens, ~r/say where your app runs: set DNS_CLUSTER_QUERY/},
          {Map.put(@tokens, "DNS_CLUSTER_QUERY", "  "), ~r/DNS_CLUSTER_QUERY/},
          {%{"PORTHOLE_TOKENS" => "nocolon", "PORTHOLE_NODES" => "h"}, ~r/id:sha256/},
          {Map.merge(@tokens, %{"PORTHOLE_NODES" => "h", "PORTHOLE_PORT" => "http"}), ~r/PORT/},
          {Map.put(@tokens, "PORTHOLE_DISCOVERY", "consul:x"), ~r/dns:<name>/},
          {Map.merge(@tokens, %{"PORTHOLE_NODES" => "h", "PORTHOLE_CERTFILE" => "c.pem"}),
           ~r/both/}
        ] do
      assert_raise ArgumentError, message, fn -> Config.from_env!(env) end
    end
  end
end

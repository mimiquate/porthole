defmodule PortholeSidecar.ConfigTest do
  use ExUnit.Case, async: true

  alias PortholeSidecar.Config

  @hash String.duplicate("ab", 32)

  test "reads a minimal configuration" do
    config =
      Config.from_env!(%{
        "PORTHOLE_TOKENS" => "oncall:#{@hash}",
        "PORTHOLE_NODES" => "app@10.0.1.12, app@10.0.1.13"
      })

    assert config.tokens == [[id: "oncall", sha256: @hash]]
    assert config.seeds == [:"app@10.0.1.12", :"app@10.0.1.13"]
    assert config.port == 4040
    assert config.ip == {0, 0, 0, 0}
    assert config.follow_peers
    assert config.tls == []
  end

  test "reads discovery, port, bind and TLS" do
    config =
      Config.from_env!(%{
        "PORTHOLE_TOKENS" => "a:#{@hash},b:#{@hash}",
        "PORTHOLE_DISCOVERY" => "dns:my-app.default.svc.cluster.local:my_app",
        "PORTHOLE_FOLLOW_PEERS" => "false",
        "PORTHOLE_PORT" => "8443",
        "PORTHOLE_BIND" => "10.0.0.5",
        "PORTHOLE_CERTFILE" => "/tls/cert.pem",
        "PORTHOLE_KEYFILE" => "/tls/key.pem"
      })

    assert length(config.tokens) == 2
    assert config.discovery == {:dns, "my-app.default.svc.cluster.local", "my_app"}
    refute config.follow_peers
    assert config.port == 8443
    assert config.ip == {10, 0, 0, 5}
    assert config.tls == [certfile: "/tls/cert.pem", keyfile: "/tls/key.pem"]
  end

  test "reads tokens with policies and the environment policy from a config file", %{} do
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

    config = Config.from_env!(%{"PORTHOLE_CONFIG" => path, "PORTHOLE_NODES" => "app@host"})
    assert [[id: "ci", sha256: _, policy: [queries_per_minute: 10]]] = config.tokens
    assert Application.get_env(:porthole, :policy) == [max_result_rows: 50]
  end

  test "explains what is missing or wrong" do
    for {env, message} <- [
          {%{"PORTHOLE_NODES" => "app@host"}, ~r/PORTHOLE_TOKENS/},
          {%{"PORTHOLE_TOKENS" => "a:#{@hash}"}, ~r/PORTHOLE_NODES or PORTHOLE_DISCOVERY/},
          {%{"PORTHOLE_TOKENS" => "nocolon", "PORTHOLE_NODES" => "a@h"}, ~r/id:sha256/},
          {%{
             "PORTHOLE_TOKENS" => "a:#{@hash}",
             "PORTHOLE_NODES" => "a@h",
             "PORTHOLE_PORT" => "http"
           }, ~r/PORT/},
          {%{"PORTHOLE_TOKENS" => "a:#{@hash}", "PORTHOLE_DISCOVERY" => "dns:only-name"},
           ~r/dns:<name>:<basename>/},
          {%{
             "PORTHOLE_TOKENS" => "a:#{@hash}",
             "PORTHOLE_NODES" => "a@h",
             "PORTHOLE_CERTFILE" => "c.pem"
           }, ~r/both/}
        ] do
      assert_raise ArgumentError, message, fn -> Config.from_env!(env) end
    end
  end
end

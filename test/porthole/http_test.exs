defmodule Porthole.HTTPTest do
  @moduledoc "MCP over HTTP against a real Bandit server, with real tokens."
  use ExUnit.Case, async: false

  alias Porthole.Auth

  @oncall Auth.generate()
  @limited Auth.generate()
  @no_tiers Auth.generate()
  @one_per_minute Auth.generate()

  setup_all do
    {:ok, _} = Application.ensure_all_started(:inets)

    tokens = [
      [id: "oncall", sha256: Auth.hash(@oncall)],
      [id: "limited", sha256: Auth.hash(@limited), policy: [max_result_rows: 1]],
      [id: "no-tiers", sha256: Auth.hash(@no_tiers), policy: [tiers: []]],
      [id: "one-per-minute", sha256: Auth.hash(@one_per_minute), policy: [queries_per_minute: 1]]
    ]

    {:ok, sup} =
      Supervisor.start_link(
        [{Porthole.Server, port: 0, tokens: tokens, allowed_origins: ["https://ok.example"]}],
        strategy: :one_for_one
      )

    [{_, server, _, _}] = Supervisor.which_children(sup)
    {:ok, {_ip, port}} = ThousandIsland.listener_info(server)
    on_exit(fn -> Process.exit(sup, :shutdown) end)
    %{url: ~c"http://127.0.0.1:#{port}/"}
  end

  setup do
    parent = self()
    Application.put_env(:porthole, :audit, {__MODULE__, :forward_audit, [parent]})
    on_exit(fn -> Application.delete_env(:porthole, :audit) end)
  end

  def forward_audit(record, pid), do: send(pid, {:audit, record})

  defp post(url, body, headers) do
    headers = Enum.map(headers, fn {k, v} -> {String.to_charlist(k), String.to_charlist(v)} end)

    {:ok, {{_, status, _}, resp_headers, resp_body}} =
      :httpc.request(:post, {url, headers, ~c"application/json", JSON.encode!(body)}, [],
        body_format: :binary
      )

    {status, Map.new(resp_headers, fn {k, v} -> {to_string(k), to_string(v)} end), resp_body}
  end

  defp rpc(url, token, method, params \\ %{}, headers \\ []) do
    message = %{"jsonrpc" => "2.0", "id" => 1, "method" => method, "params" => params}
    post(url, message, [{"authorization", "Bearer #{token}"} | headers])
  end

  defp query(url, token, sql) do
    {200, _, body} =
      rpc(url, token, "tools/call", %{"name" => "query", "arguments" => %{"sql" => sql}})

    %{"result" => %{"content" => [%{"text" => text}], "isError" => error?}} = JSON.decode!(body)
    {error?, text}
  end

  test "a valid token can initialize and query", %{url: url} do
    {200, headers, body} = rpc(url, @oncall, "initialize", %{"protocolVersion" => "2025-06-18"})
    assert headers["content-type"] =~ "application/json"
    assert %{"result" => %{"serverInfo" => %{"name" => "porthole"}}} = JSON.decode!(body)

    {false, text} =
      query(url, @oncall, "SELECT count(*) FROM applications WHERE name = 'porthole'")

    assert %{"rows" => [[1]]} = JSON.decode!(text)
  end

  test "requests without a valid token are rejected", %{url: url} do
    {401, headers, _} = post(url, %{"jsonrpc" => "2.0", "id" => 1, "method" => "ping"}, [])
    assert headers["www-authenticate"] == "Bearer"

    assert {401, _, _} = rpc(url, "ph_wrong", "ping")
    assert {401, _, _} = rpc(url, "", "ping")
  end

  test "each token's policy narrows its queries", %{url: url} do
    {false, text} = query(url, @limited, "SELECT pid FROM processes")
    assert %{"rows" => [_], "truncated" => true} = JSON.decode!(text)

    assert {true, "error (not_allowed)" <> _} = query(url, @no_tiers, "SELECT 1")
  end

  test "each client is rate limited by its token's policy", %{url: url} do
    assert {false, _} = query(url, @one_per_minute, "SELECT 1")
    assert {true, "error (rate_limited)" <> _} = query(url, @one_per_minute, "SELECT 1")

    # Other clients are unaffected.
    assert {false, _} = query(url, @oncall, "SELECT 1")
  end

  test "queries are audited with the client identity", %{url: url} do
    query(url, @oncall, "SELECT 1")

    assert_receive {:audit,
                    %{
                      client: "oncall",
                      remote_ip: "127.0.0.1",
                      sql: "SELECT 1",
                      status: "ok",
                      rows: 1
                    }}

    query(url, @oncall, "DELETE FROM processes")
    assert_receive {:audit, %{client: "oncall", status: "error", error: "read_only: " <> _}}
  end

  test "browser origins are rejected unless allowed", %{url: url} do
    assert {403, _, _} = rpc(url, @oncall, "ping", %{}, [{"origin", "https://evil.example"}])
    assert {200, _, _} = rpc(url, @oncall, "ping", %{}, [{"origin", "https://ok.example"}])
  end

  test "protocol edges", %{url: url} do
    notification = %{"jsonrpc" => "2.0", "method" => "notifications/initialized"}
    assert {202, _, ""} = post(url, notification, [{"authorization", "Bearer #{@oncall}"}])

    {:ok, {{_, 405, _}, headers, _}} = :httpc.request(:get, {url, []}, [], [])
    assert {~c"allow", ~c"POST"} in headers

    {:ok, {{_, 400, _}, _, _}} =
      :httpc.request(
        :post,
        {url, [{~c"authorization", ~c"Bearer #{@oncall}"}], ~c"application/json", "{nope"},
        [],
        []
      )
  end

  test "the server refuses to start without tokens" do
    assert_raise ArgumentError, ~r/at least one token/, fn ->
      Porthole.MCP.Plug.init(tokens: [])
    end
  end
end

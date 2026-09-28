defmodule Porthole.DevEndpointTest do
  @moduledoc "Porthole mounted inside an app, the way a Phoenix router would."
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog
  import Plug.Test

  # A router like an app's: JSON already parsed by Plug.Parsers, Porthole
  # forwarded under a path, development mode.
  defmodule Router do
    use Plug.Router

    plug(Plug.Parsers, parsers: [:json], json_decoder: JSON)
    plug(:match)
    plug(:dispatch)

    forward("/porthole", to: Porthole.MCP.Plug, init_opts: [auth: :localhost])
    match(_, do: send_resp(conn, 404, "app route"))
  end

  @query %{
    "jsonrpc" => "2.0",
    "id" => 1,
    "method" => "tools/call",
    "params" => %{"name" => "query", "arguments" => %{"sql" => "SELECT 1 AS one"}}
  }

  defp post(body, fun \\ & &1) do
    conn(:post, "/porthole", JSON.encode!(body))
    |> Plug.Conn.put_req_header("content-type", "application/json")
    |> fun.()
    |> Router.call(Router.init([]))
  end

  test "localhost can query without a token, through Plug.Parsers" do
    conn = post(@query)
    assert conn.status == 200

    assert %{"result" => %{"isError" => false, "content" => [%{"text" => text}]}} =
             JSON.decode!(conn.resp_body)

    assert %{"rows" => [[1]]} = JSON.decode!(text)
  end

  test "other peers are rejected" do
    assert post(@query, &%{&1 | remote_ip: {10, 0, 0, 7}}).status == 403
  end

  test "proxied requests are rejected, even from localhost" do
    for header <- ["x-forwarded-for", "forwarded", "x-real-ip"] do
      assert post(@query, &Plug.Conn.put_req_header(&1, header, "203.0.113.9")).status == 403
    end
  end

  test "browsers are rejected by the Origin check" do
    assert post(@query, &Plug.Conn.put_req_header(&1, "origin", "http://localhost:4000")).status ==
             403
  end

  test "the app's other routes are untouched" do
    assert Router.call(conn(:get, "/products"), Router.init([])).resp_body == "app route"
  end

  test "health checks need no auth and reveal nothing" do
    conn = Router.call(conn(:get, "/porthole/healthz"), Router.init([]))
    assert {conn.status, conn.resp_body} == {200, "ok"}
  end

  test "development mode warns when initialized" do
    log = capture_log(fn -> Porthole.MCP.Plug.init(auth: :localhost) end)
    assert log =~ "development mode"
    assert log =~ "Never enable auth: :localhost in production"
  end

  test "unknown auth modes fail at startup" do
    assert_raise ArgumentError, ~r/auth must be/, fn -> Porthole.MCP.Plug.init(auth: :none) end
  end
end

defmodule Porthole.MCPTest do
  use ExUnit.Case, async: true

  alias Porthole.MCP

  @context %{client: "test", opts: []}

  defp call(method, params \\ %{}),
    do:
      MCP.handle(
        %{"jsonrpc" => "2.0", "id" => 1, "method" => method, "params" => params},
        @context
      )

  defp query(args), do: call("tools/call", %{"name" => "query", "arguments" => args}).result

  test "initialize and tools/list" do
    assert %{result: %{protocolVersion: "2025-06-18", serverInfo: %{name: "porthole"}}} =
             call("initialize", %{"protocolVersion" => "2025-06-18"})

    assert %{result: %{tools: [%{name: "query", description: description}]}} = call("tools/list")
    assert description =~ "reductions_delta"
  end

  test "query returns JSON rows" do
    assert %{isError: false, content: [%{text: text}]} = query(%{"sql" => "SELECT 1 AS one"})
    assert %{"columns" => ["one"], "rows" => [[1]], "truncated" => false} = JSON.decode!(text)
  end

  test "query errors are readable tool results" do
    assert %{isError: true, content: [%{text: "error (read_only)" <> _}]} =
             query(%{"sql" => "DELETE FROM processes"})

    assert %{isError: false} =
             query(%{"sql" => "SELECT max(reductions_delta) FROM processes", "window_ms" => 20})
  end

  test "notifications and protocol errors" do
    assert MCP.handle(%{"jsonrpc" => "2.0", "method" => "notifications/initialized"}, @context) ==
             nil

    assert %{error: %{code: -32601}} = call("resources/list")
    assert %{error: %{code: -32602}} = call("tools/call", %{"name" => "rm"})
  end
end

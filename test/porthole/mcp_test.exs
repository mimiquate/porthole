defmodule Porthole.MCPTest do
  use ExUnit.Case, async: false

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

    # A version the server does not implement gets its latest, not an echo.
    assert %{result: %{protocolVersion: "2025-11-25"}} =
             call("initialize", %{"protocolVersion" => "1999-01-01"})

    assert %{result: %{protocolVersion: "2025-11-25"}} = call("initialize", %{})

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

  test "queries with a dynamic node set are audited with the nodes they ran on" do
    context = %{client: "sidecar", opts: [nodes: fn -> [node()] end]}
    Application.put_env(:porthole, :audit, {__MODULE__, :forward_audit, [self()]})
    on_exit(fn -> Application.delete_env(:porthole, :audit) end)

    message = %{
      "jsonrpc" => "2.0",
      "id" => 1,
      "method" => "tools/call",
      "params" => %{"name" => "query", "arguments" => %{"sql" => "SELECT 1"}}
    }

    assert %{result: %{isError: false}} = MCP.handle(message, context)
    assert_receive {:audit, %{client: "sidecar", nodes: [n]}}
    assert n == to_string(node())
  end

  def forward_audit(record, pid), do: send(pid, {:audit, record})

  test "the trace argument reaches the query, and tracing is described only when enabled" do
    assert %{result: %{tools: [%{description: description, inputSchema: schema}]}} =
             call("tools/list")

    refute description =~ "trace_messages"
    assert schema.properties.trace.maxProperties == 1

    assert %{isError: true, content: [%{text: "error (not_allowed)" <> _}]} =
             query(%{
               "sql" => "SELECT * FROM trace_messages",
               "window_ms" => 50,
               "trace" => %{"messages_to" => "porthole_mcp_test"}
             })

    Application.put_env(:porthole, :policy, tiers: [:observe, :trace])
    on_exit(fn -> Application.delete_env(:porthole, :policy) end)

    assert %{result: %{tools: [%{description: description}]}} = call("tools/list")
    assert description =~ "trace_messages"
    assert description =~ "messages_to"

    Process.register(self(), :porthole_mcp_test)

    assert %{isError: false, content: [%{text: text}]} =
             query(%{
               "sql" => "SELECT count(*) FROM trace_messages",
               "window_ms" => 50,
               "trace" => %{"messages_to" => "porthole_mcp_test"}
             })

    assert %{"rows" => [[_count]]} = JSON.decode!(text)
  end

  test "notifications and protocol errors" do
    assert MCP.handle(%{"jsonrpc" => "2.0", "method" => "notifications/initialized"}, @context) ==
             nil

    assert %{error: %{code: -32601}} = call("resources/list")
    assert %{error: %{code: -32602}} = call("tools/call", %{"name" => "rm"})
  end
end

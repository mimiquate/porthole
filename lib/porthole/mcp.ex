defmodule Porthole.MCP do
  @moduledoc """
  The MCP protocol, exposing one tool, `query`, whose description embeds the
  schema.

  `handle/2` is the transport-independent protocol. Two transports use it:
  `serve/1` (stdio, newline-delimited JSON-RPC, for local use) and
  `Porthole.MCP.Plug` (Streamable HTTP, for a sidecar in production).

  Every query is recorded with `Porthole.Audit`.
  """

  alias Porthole.Audit

  @typedoc """
  Who is asking and with which defaults:

    * `:client` - the client id recorded in the audit log.
    * `:remote_ip` - the client address, when known.
    * `:opts` - query options applied to every query (nodes, window,
      policy); request arguments are merged on top and can only narrow the
      policy.
  """
  @type context :: %{
          required(:client) => String.t(),
          required(:opts) => keyword(),
          optional(:remote_ip) => String.t()
        }

  @doc "Serves MCP on stdio until stdin closes. `query_opts` apply to every query."
  @spec serve(keyword()) :: :ok
  def serve(query_opts \\ []) do
    {:ok, config} = :logger.get_handler_config(:default)
    :ok = :logger.remove_handler(:default)

    :ok =
      :logger.add_handler(
        :default,
        :logger_std_h,
        put_in(config, [:config, :type], :standard_error)
      )

    loop(%{client: "stdio", opts: query_opts})
  end

  defp loop(context) do
    case IO.read(:stdio, :line) do
      line when is_binary(line) ->
        reply =
          case JSON.decode(line) do
            {:ok, message} -> handle(message, context)
            {:error, _} -> error(nil, -32700, "parse error")
          end

        if reply, do: IO.write([JSON.encode!(reply), ?\n])
        loop(context)

      _eof_or_error ->
        :ok
    end
  end

  @doc "Handles one JSON-RPC message. Returns the reply, or `nil` for notifications."
  @spec handle(term(), context()) :: map() | nil
  def handle(%{"id" => id, "method" => method} = message, context) do
    case request(method, message["params"] || %{}, context) do
      {:ok, result} -> %{jsonrpc: "2.0", id: id, result: result}
      {:error, code, text} -> error(id, code, text)
    end
  end

  def handle(%{"method" => _notification}, _context), do: nil
  def handle(_other, _context), do: error(nil, -32600, "invalid request")

  @doc false
  @spec error(term(), integer(), String.t()) :: map()
  def error(id, code, message),
    do: %{jsonrpc: "2.0", id: id, error: %{code: code, message: message}}

  defp request("initialize", params, _context) do
    {:ok,
     %{
       protocolVersion: params["protocolVersion"] || "2025-06-18",
       capabilities: %{tools: %{}},
       serverInfo: %{name: "porthole", version: to_string(Application.spec(:porthole, :vsn))}
     }}
  end

  defp request("ping", _params, _context), do: {:ok, %{}}
  defp request("tools/list", _params, _context), do: {:ok, %{tools: [tool()]}}

  defp request("tools/call", %{"name" => "query", "arguments" => %{"sql" => sql} = args}, context)
       when is_binary(sql) do
    request_opts =
      for {key, value} <- [window_ms: args["window_ms"], nodes: args["nodes"]],
          value != nil,
          do: {key, value}

    opts = context.opts |> Keyword.merge(request_opts) |> Keyword.put(:client, context.client)
    started = System.monotonic_time(:millisecond)
    outcome = Porthole.query(sql, opts)
    Audit.record(context, sql, opts, outcome, System.monotonic_time(:millisecond) - started)

    {:ok,
     case outcome do
       {:ok, result} ->
         %{content: [%{type: "text", text: JSON.encode!(result)}], isError: false}

       # Query errors are tool results, so the agent reads them and retries.
       {:error, error} ->
         %{content: [%{type: "text", text: Porthole.format({:error, error})}], isError: true}
     end}
  end

  defp request("tools/call", _params, _context),
    do: {:error, -32602, "unknown tool or missing sql"}

  defp request(method, _params, _context), do: {:error, -32601, "method not found: #{method}"}

  defp tool do
    %{
      name: "query",
      description: description(),
      inputSchema: %{
        type: "object",
        properties: %{
          sql: %{type: "string", description: "One read-only SQLite SELECT."},
          window_ms: %{
            type: "integer",
            description: "Sample over this window to get _delta columns, e.g. 5000."
          },
          nodes: %{
            type: "array",
            items: %{type: "string"},
            description: "Nodes to query. Default: the target node."
          }
        },
        required: ["sql"]
      },
      annotations: %{readOnlyHint: true}
    }
  end

  defp description do
    tables =
      for table <- Porthole.schema() do
        columns = Enum.map_join(table.columns, "\n", &"    #{&1.name} (#{&1.type}): #{&1.doc}")

        sampled =
          if table.sampled == [],
            do: "",
            else: "\n  with window_ms: #{Enum.join(table.sampled, ", ")}"

        "- #{table.name}: #{table.description}\n    node (text)\n#{columns}#{sampled}"
      end

    """
    Read-only SQL (SQLite) over the live Erlang/Elixir system. Tables are collected fresh for every \
    query; this is not an atomic snapshot. Every table has a `node` column: join on it as well as on pids. \
    Booleans are 0/1, memory is in bytes. Results are capped: if `truncated` is true, read `notes`. \
    If `errors` is not empty, rows from those nodes are missing from the result.

    #{Enum.join(tables, "\n")}
    """
  end
end

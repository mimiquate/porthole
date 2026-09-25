defmodule Porthole.MCP do
  @moduledoc """
  An MCP server over stdio (newline-delimited JSON-RPC), exposing one tool,
  `query`, whose description embeds the schema.

  `handle/2` is the protocol, and `serve/1` is the stdio loop. stdout carries
  protocol messages only, so `serve/1` sends logs to stderr.

  Every query an agent runs is logged at `:info` level (SQL, nodes, outcome),
  which is the audit trail of what the agent looked at.
  """

  require Logger

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

    loop(query_opts)
  end

  defp loop(query_opts) do
    case IO.read(:stdio, :line) do
      line when is_binary(line) ->
        reply =
          case JSON.decode(line) do
            {:ok, message} -> handle(message, query_opts)
            {:error, _} -> error(nil, -32700, "parse error")
          end

        if reply, do: IO.write([JSON.encode!(reply), ?\n])
        loop(query_opts)

      _eof_or_error ->
        :ok
    end
  end

  @doc "Handles one JSON-RPC message. Returns the reply, or `nil` for notifications."
  @spec handle(map(), keyword()) :: map() | nil
  def handle(%{"id" => id, "method" => method} = message, query_opts) do
    case request(method, message["params"] || %{}, query_opts) do
      {:ok, result} -> %{jsonrpc: "2.0", id: id, result: result}
      {:error, code, text} -> error(id, code, text)
    end
  end

  def handle(%{"method" => _notification}, _query_opts), do: nil
  def handle(_other, _query_opts), do: error(nil, -32600, "invalid request")

  defp request("initialize", params, _opts) do
    {:ok,
     %{
       protocolVersion: params["protocolVersion"] || "2025-06-18",
       capabilities: %{tools: %{}},
       serverInfo: %{name: "porthole", version: to_string(Application.spec(:porthole, :vsn))}
     }}
  end

  defp request("ping", _params, _opts), do: {:ok, %{}}
  defp request("tools/list", _params, _opts), do: {:ok, %{tools: [tool()]}}

  defp request("tools/call", %{"name" => "query", "arguments" => %{"sql" => sql} = args}, opts)
       when is_binary(sql) do
    request_opts =
      for {key, value} <- [window_ms: args["window_ms"], nodes: args["nodes"]],
          value != nil,
          do: {key, value}

    opts = Keyword.merge(opts, request_opts)
    outcome = Porthole.query(sql, opts)
    audit(sql, opts, outcome)

    {:ok,
     case outcome do
       {:ok, result} ->
         %{content: [%{type: "text", text: JSON.encode!(result)}], isError: false}

       # Query errors are tool results, so the agent reads them and retries.
       {:error, error} ->
         %{content: [%{type: "text", text: Porthole.format({:error, error})}], isError: true}
     end}
  end

  defp request("tools/call", _params, _opts), do: {:error, -32602, "unknown tool or missing sql"}
  defp request(method, _params, _opts), do: {:error, -32601, "method not found: #{method}"}

  defp audit(sql, opts, outcome) do
    status =
      case outcome do
        {:ok, result} -> "#{length(result.rows)} rows#{if result.truncated, do: " (truncated)"}"
        {:error, error} -> "error #{error.reason}"
      end

    Logger.info(
      "porthole query [#{status}] nodes=#{inspect(opts[:nodes])} window_ms=#{inspect(opts[:window_ms])}: #{sql}"
    )
  end

  defp error(id, code, message),
    do: %{jsonrpc: "2.0", id: id, error: %{code: code, message: message}}

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
    Booleans are 0/1, memory is in bytes. Results are capped: if `truncated` is true, read `notes`.

    #{Enum.join(tables, "\n")}
    """
  end
end

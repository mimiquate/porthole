if Code.ensure_loaded?(Plug) do
  defmodule Porthole.MCP.Plug do
    @moduledoc """
    MCP over HTTP (the "Streamable HTTP" transport), for a sidecar that keeps
    the distribution cookie inside the cluster.

    Agents send JSON-RPC in `POST` requests with an `Authorization: Bearer`
    token and get JSON back. The server is stateless: no sessions, no
    server-initiated streams, so `GET` and `DELETE` answer 405, as the
    transport allows.

    Security checks on every request, before any work is done:

      * **Bearer token** (`Porthole.Auth`): unknown or missing tokens get 401.
        The token's policy becomes the session policy of every query.
      * **Origin**: requests carrying an `Origin` header are rejected unless
        it is explicitly allowed, which protects against DNS rebinding from
        browsers. Agents do not send `Origin`.
      * **Body size**: requests over 1 MB are rejected.

    Usually started through `Porthole.Server`, but it can be mounted in any
    Plug pipeline:

        forward "/mcp", to: Porthole.MCP.Plug, init_opts: [tokens: tokens, query_opts: [nodes: :all]]

    ## Options

      * `:tokens` - token configuration (see `Porthole.Auth`). Defaults to
        `config :porthole, :tokens`. At least one token is required.
      * `:query_opts` - options applied to every query (e.g. `nodes: :all`).
      * `:allowed_origins` - `Origin` values to accept. Default: none.
    """

    @behaviour Plug

    import Plug.Conn

    alias Porthole.{Auth, MCP}

    @max_body 1_000_000

    @impl true
    def init(opts) do
      tokens =
        Keyword.get_lazy(opts, :tokens, fn -> Application.get_env(:porthole, :tokens, []) end)

      clients = Auth.load!(tokens)

      if clients == [] do
        raise ArgumentError,
              "Porthole's HTTP server needs at least one token; generate one with mix porthole.gen.token"
      end

      %{
        clients: clients,
        query_opts: Keyword.get(opts, :query_opts, []),
        allowed_origins: Keyword.get(opts, :allowed_origins, [])
      }
    end

    @impl true
    def call(conn, config) do
      with :ok <- check_method(conn),
           :ok <- check_origin(conn, config),
           {:ok, client} <- authenticate(conn, config),
           {:ok, message, conn} <- read_message(conn) do
        context = %{
          client: client.id,
          remote_ip: conn.remote_ip |> :inet.ntoa() |> to_string(),
          opts: Keyword.put(config.query_opts, :policy, client.policy)
        }

        case MCP.handle(message, context) do
          nil -> send_resp(conn, 202, "")
          reply -> json(conn, 200, reply)
        end
      else
        {:error, status, message} -> reject(conn, status, message)
      end
    end

    defp check_method(%{method: "POST"}), do: :ok
    defp check_method(_conn), do: {:error, 405, "only POST is supported"}

    defp check_origin(conn, config) do
      case get_req_header(conn, "origin") do
        [] ->
          :ok

        [origin] ->
          if origin in config.allowed_origins, do: :ok, else: {:error, 403, "origin not allowed"}

        _many ->
          {:error, 403, "origin not allowed"}
      end
    end

    defp authenticate(conn, config) do
      with ["Bearer " <> token] <- get_req_header(conn, "authorization"),
           {:ok, client} <- Auth.verify(config.clients, String.trim(token)) do
        {:ok, client}
      else
        _ -> {:error, 401, "missing or invalid bearer token"}
      end
    end

    defp read_message(conn) do
      case read_body(conn, length: @max_body) do
        {:ok, body, conn} ->
          case JSON.decode(body) do
            {:ok, message} -> {:ok, message, conn}
            {:error, _} -> {:error, 400, "body is not valid JSON"}
          end

        {:more, _partial, _conn} ->
          {:error, 413, "request body is too large"}

        {:error, _reason} ->
          {:error, 400, "could not read the request body"}
      end
    end

    defp reject(conn, 405, message) do
      conn |> put_resp_header("allow", "POST") |> json(405, MCP.error(nil, -32600, message))
    end

    defp reject(conn, 401, message) do
      conn
      |> put_resp_header("www-authenticate", "Bearer")
      |> json(401, MCP.error(nil, -32001, message))
    end

    defp reject(conn, status, message), do: json(conn, status, MCP.error(nil, -32600, message))

    defp json(conn, status, body) do
      conn
      |> put_resp_content_type("application/json")
      |> send_resp(status, JSON.encode!(body))
    end
  end
end

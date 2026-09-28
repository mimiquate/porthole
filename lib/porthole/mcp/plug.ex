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

    `GET /healthz` answers `200 ok` without authentication and without
    revealing anything, for load balancers and orchestrators.

    Usually started through `Porthole.Server`, but it can be mounted in any
    Plug pipeline, including a Phoenix router (a body already parsed by
    `Plug.Parsers` is used as is):

        forward "/porthole", Porthole.MCP.Plug, tokens: tokens

    ## Development mode

    With `auth: :localhost`, no token is needed, for mounting Porthole inside
    your app during development:

        # lib/my_app_web/router.ex
        if Mix.env() == :dev do
          forward "/porthole", Porthole.MCP.Plug, auth: :localhost
        end

    Requests are then accepted only when they come straight from the same
    machine: the peer must be a loopback address, and requests carrying proxy
    headers (`x-forwarded-for`, `forwarded`, `x-real-ip`) are rejected, since
    behind a reverse proxy on the same host every request would appear to
    come from localhost. Browsers are still blocked by the `Origin` check. A
    warning is logged when the plug is initialized in this mode (in a Phoenix
    router, that happens when the router compiles). Never enable it in
    production.

    ## Options

      * `:auth` - `:tokens` (default) or `:localhost` (development only).
      * `:tokens` - token configuration (see `Porthole.Auth`). Defaults to
        `config :porthole, :tokens`. At least one token is required with
        `auth: :tokens`.
      * `:query_opts` - options applied to every query (e.g. `nodes: :all`).
      * `:allowed_origins` - `Origin` values to accept. Default: none.
    """

    @behaviour Plug

    import Plug.Conn

    require Logger

    alias Porthole.{Auth, MCP, Policy}

    @max_body 1_000_000
    @proxy_headers ["x-forwarded-for", "forwarded", "x-real-ip"]

    @impl true
    def init(opts) do
      auth = Keyword.get(opts, :auth, :tokens)

      clients =
        case auth do
          :tokens ->
            tokens =
              Keyword.get_lazy(opts, :tokens, fn ->
                Application.get_env(:porthole, :tokens, [])
              end)

            clients = Auth.load!(tokens)

            if clients == [] do
              raise ArgumentError,
                    "Porthole's HTTP server needs at least one token; generate one with " <>
                      "mix porthole.gen.token (or use auth: :localhost in development)"
            end

            clients

          :localhost ->
            Logger.warning(
              "Porthole MCP endpoint in development mode: unauthenticated access from localhost. " <>
                "Never enable auth: :localhost in production."
            )

            []

          other ->
            raise ArgumentError, "auth must be :tokens or :localhost, got: #{inspect(other)}"
        end

      %{
        auth: auth,
        clients: clients,
        query_opts: Keyword.get(opts, :query_opts, []),
        allowed_origins: Keyword.get(opts, :allowed_origins, [])
      }
    end

    @impl true
    def call(%{method: "GET", path_info: ["healthz"]} = conn, _config) do
      conn |> put_resp_content_type("text/plain") |> send_resp(200, "ok")
    end

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

    defp authenticate(conn, %{auth: :localhost}) do
      loopback? = conn.remote_ip in [{127, 0, 0, 1}, {0, 0, 0, 0, 0, 0, 0, 1}]
      proxied? = Enum.any?(@proxy_headers, &(get_req_header(conn, &1) != []))

      if loopback? and not proxied?,
        do: {:ok, %{id: "localhost", policy: Policy.new()}},
        else: {:error, 403, "development mode only accepts direct requests from localhost"}
    end

    defp authenticate(conn, config) do
      with ["Bearer " <> token] <- get_req_header(conn, "authorization"),
           {:ok, client} <- Auth.verify(config.clients, String.trim(token)) do
        {:ok, client}
      else
        _ -> {:error, 401, "missing or invalid bearer token"}
      end
    end

    # Plug.Parsers (e.g. in a Phoenix endpoint) may have read the body
    # already; JSON arrays end up under "_json".
    defp read_message(%{body_params: %{"_json" => message}} = conn), do: {:ok, message, conn}

    defp read_message(%{body_params: %{} = params} = conn)
         when not is_struct(params) and map_size(params) > 0,
         do: {:ok, params, conn}

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

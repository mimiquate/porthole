if Code.ensure_loaded?(Bandit) do
  defmodule Porthole.Server do
    @moduledoc """
    Serves `Porthole.MCP.Plug` over HTTP(S) with Bandit.

    This is the production front door: a sidecar node joins the cluster
    (holding the cookie) and exposes MCP to agents, which only ever get a URL
    and a token. Add it to a supervision tree:

        children = [
          {Porthole.Server, port: 4040, ip: {0, 0, 0, 0}, query_opts: [nodes: :all]}
        ]

    or run `mix porthole.server`.

    ## Options

      * `:port` - default 4040.
      * `:ip` - interface to listen on. Default `{127, 0, 0, 1}`: listening
        on other interfaces must be explicit.
      * `:certfile` / `:keyfile` - serve HTTPS. Without them, terminate TLS
        in front of the server: tokens must never travel in clear text
        outside a trusted network.
      * `:tokens`, `:query_opts`, `:allowed_origins` - see `Porthole.MCP.Plug`.
    """

    @doc false
    @spec child_spec(keyword()) :: Supervisor.child_spec()
    def child_spec(opts) do
      plug_opts = Keyword.take(opts, [:tokens, :query_opts, :allowed_origins])

      bandit =
        [
          plug: {Porthole.MCP.Plug, plug_opts},
          port: Keyword.get(opts, :port, 4040),
          ip: Keyword.get(opts, :ip, {127, 0, 0, 1})
        ] ++ tls(opts)

      %{id: __MODULE__, start: {Bandit, :start_link, [bandit]}, type: :supervisor}
    end

    defp tls(opts) do
      case {opts[:certfile], opts[:keyfile]} do
        {nil, nil} ->
          [scheme: :http]

        {certfile, keyfile} when is_binary(certfile) and is_binary(keyfile) ->
          [scheme: :https, certfile: certfile, keyfile: keyfile]

        _ ->
          raise ArgumentError, "HTTPS needs both :certfile and :keyfile"
      end
    end
  end
end

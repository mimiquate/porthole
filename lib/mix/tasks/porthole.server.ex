defmodule Mix.Tasks.Porthole.Server do
  @shortdoc "Serves Porthole to agents over MCP (HTTP), for production sidecars"

  @moduledoc """
  Runs Porthole as a sidecar: this VM joins the cluster (holding the cookie)
  and serves MCP over HTTP. Agents get a URL and a token, never the cookie.

      $ RELEASE_COOKIE=... mix porthole.server --connect my_app@10.0.1.12 \\
          --all-nodes --bind 0.0.0.0 --port 4040

  The cookie is read from `RELEASE_COOKIE` (or `--cookie`, which leaves it
  visible to other users of the machine).

  Tokens come from `config :porthole, :tokens` (see `mix porthole.gen.token`);
  the server refuses to start without one. Then point an agent at it, e.g.:

      $ claude mcp add --transport http porthole http://sidecar:4040/ \\
          --header "Authorization: Bearer ph_..."

  ## Options

    * `--port PORT` - default 4040.
    * `--bind IP` - default 127.0.0.1. Use 0.0.0.0 to accept remote agents.
    * `--certfile PATH` / `--keyfile PATH` - serve HTTPS. Otherwise put TLS
      in front of the server.

  Plus the connection options in `Porthole.CLI` (`--connect`, `--cookie`,
  `--node`, `--all-nodes`, `--window`, `--demo`).
  """

  use Mix.Task

  @switches [port: :integer, bind: :string, certfile: :string, keyfile: :string]

  @impl true
  def run(args) do
    {query_opts, _rest, opts} = Porthole.CLI.setup!(args, @switches)

    {:ok, ip} =
      opts |> Keyword.get(:bind, "127.0.0.1") |> String.to_charlist() |> :inet.parse_address()

    port = Keyword.get(opts, :port, 4040)

    server_opts =
      [port: port, ip: ip, query_opts: query_opts] ++ Keyword.take(opts, [:certfile, :keyfile])

    {:ok, _} = Supervisor.start_link([{Porthole.Server, server_opts}], strategy: :one_for_one)
    scheme = if opts[:certfile], do: "https", else: "http"
    Mix.shell().info("Porthole MCP server listening on #{scheme}://#{:inet.ntoa(ip)}:#{port}/")
    Process.sleep(:infinity)
  end
end

defmodule Mix.Tasks.Porthole.Gen.Token do
  @shortdoc "Generates a client token for the Porthole HTTP server"

  @moduledoc """
  Generates a token for one client (an agent, a team, a person):

      $ mix porthole.gen.token oncall
      $ mix porthole.gen.token oncall --url https://porthole.internal:4040/

  It prints the token, to give to the client, the server configuration
  (which stores only the token's hash, either in `config :porthole, :tokens`
  or in the sidecar's `PORTHOLE_TOKENS`), and the command that connects an
  agent. The token itself is not stored anywhere and cannot be recovered;
  generate a new one if it is lost.

  ## Options

    * `--url URL` - the server's URL, used in the connect command.
  """

  use Mix.Task

  @impl true
  def run(args) do
    case OptionParser.parse(args, strict: [url: :string]) do
      {opts, [id], []} -> generate(id, opts[:url])
      _ -> Mix.raise("usage: mix porthole.gen.token CLIENT_ID [--url URL]")
    end
  end

  defp generate(id, url) do
    token = Porthole.Auth.generate()
    hash = Porthole.Auth.hash(token)

    # On a first setup the sidecar is not running yet, so its URL is unknown.
    {shown_url, url_note} =
      if url,
        do: {url, ""},
        else:
          {"<SIDECAR_URL>",
           "\n    <SIDECAR_URL> is where the agent reaches the sidecar once it runs, e.g.\n" <>
             "    http://localhost:4040/ through a tunnel. Pass --url to fill it in.\n"}

    Mix.shell().info("""
    Token for #{id} (give this to the client; it is shown only once):

        #{token}

    Server configuration, either in config (one entry per client in the list):

        config :porthole, :tokens, [
          [id: #{inspect(id)}, sha256: #{inspect(hash)}]
        ]

    or, for the sidecar, in PORTHOLE_TOKENS (comma separated):

        PORTHOLE_TOKENS=#{id}:#{hash}

    Connect an agent, e.g. Claude Code:

        claude mcp add --transport http porthole #{shown_url} --header "Authorization: Bearer #{token}"
    #{url_note}
    Optionally narrow what this client sees with a policy (config file only):

        [id: #{inspect(id)}, sha256: "...", policy: [nodes: [:"my_app@10.0.1.12"], queries_per_minute: 10]]
    """)
  end
end

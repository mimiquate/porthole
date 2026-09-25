defmodule Mix.Tasks.Porthole.Gen.Token do
  @shortdoc "Generates a client token for the Porthole HTTP server"

  @moduledoc """
  Generates a token for one client (an agent, a team, a person):

      $ mix porthole.gen.token oncall

  It prints the token, to give to the client, and the configuration entry,
  which stores only the token's hash. The token itself is not stored anywhere
  and cannot be recovered; generate a new one if it is lost.
  """

  use Mix.Task

  @impl true
  def run([id]) do
    token = Porthole.Auth.generate()

    Mix.shell().info("""
    Token for #{id} (give this to the client; it is shown only once):

        #{token}

    Add the entry to the server's config (one entry per client in the list):

        config :porthole, :tokens, [
          [id: #{inspect(id)}, sha256: #{inspect(Porthole.Auth.hash(token))}]
        ]

    Optionally narrow what this client sees with a policy:

          [id: #{inspect(id)}, sha256: "...", policy: [nodes: [:"my_app@10.0.1.12"], max_result_rows: 200]]
    """)
  end

  def run(_args), do: Mix.raise("usage: mix porthole.gen.token CLIENT_ID")
end

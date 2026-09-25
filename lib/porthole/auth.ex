defmodule Porthole.Auth do
  @moduledoc """
  Bearer tokens for the HTTP front door.

  Each client (an agent, a team, a person) gets its own token. Only the
  token's SHA-256 hash is stored in configuration, next to an id used in the
  audit log and an optional policy that narrows what the client can see:

      config :porthole, :tokens, [
        [id: "oncall", sha256: "9f86d0...", policy: [nodes: [:"app@10.0.1.12"]]],
        [id: "ci-deploy-check", sha256: "60303a...", policy: [max_result_rows: 50]]
      ]

  Generate tokens with `mix porthole.gen.token`. The token policy is the
  *session* layer of `environment ∩ session ∩ request`, so it can only narrow
  the environment policy. Removing an entry revokes the token.
  """

  alias Porthole.Policy

  @type client :: %{id: String.t(), hash: binary(), policy: Policy.t()}

  @prefix "ph_"

  @doc "Generates a new random token."
  @spec generate() :: String.t()
  def generate, do: @prefix <> Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)

  @doc "The hex SHA-256 hash of a token, as stored in config."
  @spec hash(String.t()) :: String.t()
  def hash(token), do: :crypto.hash(:sha256, token) |> Base.encode16(case: :lower)

  @doc """
  Validates token configuration, raising on mistakes so a misconfigured
  server fails at startup rather than at the first request.
  """
  @spec load!([keyword() | map()]) :: [client()]
  def load!(entries) do
    # A common slip: a single entry given as the whole value.
    if not is_list(entries) or (Keyword.keyword?(entries) and entries != []) do
      raise ArgumentError, """
      config :porthole, :tokens must be a list of entries, one per client, e.g.:

          config :porthole, :tokens, [
            [id: "oncall", sha256: "..."]
          ]

      got: #{inspect(entries)}
      """
    end

    clients =
      for entry <- entries do
        entry = Map.new(entry)
        id = entry[:id] || raise ArgumentError, "every token needs an :id, got: #{inspect(entry)}"

        hash =
          with hex when is_binary(hex) <- entry[:sha256],
               {:ok, hash} when byte_size(hash) == 32 <- Base.decode16(hex, case: :mixed) do
            hash
          else
            _ ->
              raise ArgumentError,
                    "token #{inspect(id)} needs :sha256, a hex SHA-256 hash (see mix porthole.gen.token)"
          end

        %{id: to_string(id), hash: hash, policy: Policy.new(entry[:policy] || [])}
      end

    ids = Enum.map(clients, & &1.id)

    if ids != Enum.uniq(ids),
      do: raise(ArgumentError, "token ids must be unique, got: #{inspect(ids)}")

    clients
  end

  @doc """
  Finds the client a presented token belongs to. Every configured hash is
  compared in constant time, so timing does not reveal which (or whether a)
  token almost matched.
  """
  @spec verify([client()], String.t()) :: {:ok, client()} | :error
  def verify(clients, token) when is_binary(token) do
    presented = :crypto.hash(:sha256, token)

    clients
    |> Enum.filter(&:crypto.hash_equals(&1.hash, presented))
    |> case do
      [client] -> {:ok, client}
      _ -> :error
    end
  end
end

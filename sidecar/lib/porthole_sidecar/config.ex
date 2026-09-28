defmodule PortholeSidecar.Config do
  @moduledoc """
  The sidecar's configuration, read from environment variables at startup.

  | Variable | Meaning | Default |
  |---|---|---|
  | `PORTHOLE_TOKENS` | Clients, as `id:sha256,id:sha256` (hashes from `mix porthole.gen.token`) | required, unless set in `PORTHOLE_CONFIG` |
  | `PORTHOLE_NODES` | Seed nodes, comma separated, e.g. `my_app@10.0.1.12` | |
  | `PORTHOLE_DISCOVERY` | DNS discovery, `dns:<name>:<basename>`: every A/AAAA record of `<name>` is a node `<basename>@<ip>` | |
  | `PORTHOLE_FOLLOW_PEERS` | Also observe every node the seeds are connected to | `true` |
  | `PORTHOLE_PORT` | HTTP port | `4040` |
  | `PORTHOLE_BIND` | Interface to listen on | `0.0.0.0` |
  | `PORTHOLE_CERTFILE`, `PORTHOLE_KEYFILE` | Serve HTTPS | |
  | `PORTHOLE_CONFIG` | Path to an Elixir config file for anything else (per-token policies, the environment policy) | |

  At least one of `PORTHOLE_NODES` or `PORTHOLE_DISCOVERY` is required. The
  node name and cookie come from the release's own variables
  (`RELEASE_NODE`, `RELEASE_DISTRIBUTION`, `RELEASE_COOKIE`).

  `PORTHOLE_CONFIG` points to a file in the usual config format:

      import Config

      config :porthole, :tokens, [
        [id: "oncall", sha256: "fd07d5..."],
        [id: "ci", sha256: "60303a...", policy: [queries_per_minute: 10]]
      ]

      config :porthole, :policy, max_result_rows: 200

  Tokens from `PORTHOLE_TOKENS` are added to those from the file.
  """

  @type t :: %{
          tokens: [keyword()],
          seeds: [node()],
          discovery: nil | {:dns, String.t(), String.t()},
          follow_peers: boolean(),
          port: pos_integer(),
          ip: :inet.ip_address(),
          tls: keyword()
        }

  @doc "Reads the configuration from `env` (the process environment by default)."
  @spec from_env!(%{String.t() => String.t()}) :: t()
  def from_env!(env \\ System.get_env()) do
    file_config = load_file(env["PORTHOLE_CONFIG"])

    config = %{
      tokens: file_config[:tokens] ++ parse_tokens(env["PORTHOLE_TOKENS"]),
      seeds: env |> Map.get("PORTHOLE_NODES", "") |> split() |> Enum.map(&String.to_atom/1),
      discovery: parse_discovery(env["PORTHOLE_DISCOVERY"]),
      follow_peers: env["PORTHOLE_FOLLOW_PEERS"] not in ["false", "0"],
      port: parse_port(Map.get(env, "PORTHOLE_PORT", "4040")),
      ip: parse_ip(Map.get(env, "PORTHOLE_BIND", "0.0.0.0")),
      tls: parse_tls(env["PORTHOLE_CERTFILE"], env["PORTHOLE_KEYFILE"])
    }

    if config.tokens == [], do: fail("set PORTHOLE_TOKENS (or :tokens in PORTHOLE_CONFIG)")

    if config.seeds == [] and config.discovery == nil,
      do: fail("set PORTHOLE_NODES or PORTHOLE_DISCOVERY to say which nodes to observe")

    config
  end

  defp load_file(nil), do: %{tokens: []}

  defp load_file(path) do
    config = Config.Reader.read!(path)
    porthole = Keyword.get(config, :porthole, [])
    # The environment policy is read from the application environment.
    if policy = porthole[:policy], do: Application.put_env(:porthole, :policy, policy)
    %{tokens: Keyword.get(porthole, :tokens, [])}
  end

  defp parse_tokens(nil), do: []

  defp parse_tokens(value) do
    for entry <- split(value) do
      case String.split(entry, ":", parts: 2) do
        [id, sha256] when id != "" and sha256 != "" -> [id: id, sha256: sha256]
        _ -> fail("PORTHOLE_TOKENS entries must be id:sha256, got: #{inspect(entry)}")
      end
    end
  end

  defp parse_discovery(nil), do: nil
  defp parse_discovery(""), do: nil

  defp parse_discovery("dns:" <> rest) do
    case String.split(rest, ":") do
      [name, basename] when name != "" and basename != "" -> {:dns, name, basename}
      _ -> fail("PORTHOLE_DISCOVERY must be dns:<name>:<basename>, got: dns:#{rest}")
    end
  end

  defp parse_discovery(other), do: fail("unsupported PORTHOLE_DISCOVERY: #{inspect(other)}")

  defp parse_port(value) do
    case Integer.parse(value) do
      {port, ""} when port in 1..65_535 -> port
      _ -> fail("PORTHOLE_PORT must be a port number, got: #{inspect(value)}")
    end
  end

  defp parse_ip(value) do
    case :inet.parse_address(String.to_charlist(value)) do
      {:ok, ip} -> ip
      {:error, _} -> fail("PORTHOLE_BIND must be an IP address, got: #{inspect(value)}")
    end
  end

  defp parse_tls(nil, nil), do: []

  defp parse_tls(cert, key) when is_binary(cert) and is_binary(key),
    do: [certfile: cert, keyfile: key]

  defp parse_tls(_, _), do: fail("HTTPS needs both PORTHOLE_CERTFILE and PORTHOLE_KEYFILE")

  defp split(value), do: value |> String.split(",", trim: true) |> Enum.map(&String.trim/1)

  defp fail(message), do: raise(ArgumentError, "Porthole sidecar: " <> message)
end

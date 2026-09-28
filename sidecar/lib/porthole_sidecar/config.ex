defmodule PortholeSidecar.Config do
  @moduledoc """
  The sidecar's configuration, read from environment variables at startup.

  The sidecar needs to know **where** your app's nodes are, not their exact
  names: it asks each host's Erlang port mapper (epmd, port 4369, already
  reachable in any cluster) which nodes run there. So in the common case you
  reuse what your app already uses to find its own nodes:

  | Variable | Meaning | Default |
  |---|---|---|
  | `DNS_CLUSTER_QUERY` | The DNS name your app already clusters with (Phoenix's `dns_cluster`); every address it resolves to is a host to look at | |
  | `PORTHOLE_NODES` | Hosts (`10.0.1.12`) or full node names (`shop@10.0.1.12`), comma separated | |
  | `PORTHOLE_DISCOVERY` | Like `DNS_CLUSTER_QUERY`, as `dns:<name>`, when the app uses another variable | |
  | `PORTHOLE_NODE_PREFIX` | Only observe nodes whose name starts with this (when hosts run other Erlang nodes) | all |
  | `PORTHOLE_TOKENS` | Clients, as `id:sha256,id:sha256` (from `mix porthole.gen.token`) | required, unless in `PORTHOLE_CONFIG` |
  | `PORTHOLE_FOLLOW_PEERS` | Also observe every node the found nodes are connected to | `true` |
  | `PORTHOLE_PORT` / `PORTHOLE_BIND` | Where to listen | `4040` / `0.0.0.0` |
  | `PORTHOLE_CERTFILE`, `PORTHOLE_KEYFILE` | Serve HTTPS | |
  | `PORTHOLE_CONFIG` | An Elixir config file for per-token policies and the environment policy | |

  At least one of `DNS_CLUSTER_QUERY`, `PORTHOLE_DISCOVERY` or
  `PORTHOLE_NODES` is required. The sidecar's own name and cookie come from
  the release (`RELEASE_COOKIE`, and `RELEASE_NODE`, which defaults to
  `porthole@<this machine's IP>`).

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
          nodes: [node()],
          hosts: [String.t()],
          dns: [String.t()],
          prefix: String.t() | nil,
          follow_peers: boolean(),
          port: pos_integer(),
          ip: :inet.ip_address(),
          tls: keyword()
        }

  @doc "Reads the configuration from `env` (the process environment by default)."
  @spec from_env!(%{String.t() => String.t()}) :: t()
  def from_env!(env \\ System.get_env()) do
    file_config = load_file(env["PORTHOLE_CONFIG"])

    {nodes, hosts} =
      env |> Map.get("PORTHOLE_NODES", "") |> split() |> Enum.split_with(&(&1 =~ "@"))

    config = %{
      tokens: file_config[:tokens] ++ parse_tokens(env["PORTHOLE_TOKENS"]),
      nodes: Enum.map(nodes, &String.to_atom/1),
      hosts: hosts,
      dns: parse_dns(env["PORTHOLE_DISCOVERY"], env["DNS_CLUSTER_QUERY"]),
      prefix: blank_to_nil(env["PORTHOLE_NODE_PREFIX"]),
      follow_peers: env["PORTHOLE_FOLLOW_PEERS"] not in ["false", "0"],
      port: parse_port(Map.get(env, "PORTHOLE_PORT", "4040")),
      ip: parse_ip(Map.get(env, "PORTHOLE_BIND", "0.0.0.0")),
      tls: parse_tls(env["PORTHOLE_CERTFILE"], env["PORTHOLE_KEYFILE"])
    }

    if config.tokens == [], do: fail("set PORTHOLE_TOKENS (or :tokens in PORTHOLE_CONFIG)")

    if config.nodes == [] and config.hosts == [] and config.dns == [] do
      fail(
        "say where your app runs: set DNS_CLUSTER_QUERY (the DNS name your app clusters with), " <>
          "or PORTHOLE_NODES (hosts or node names)"
      )
    end

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

  # PORTHOLE_DISCOVERY wins over DNS_CLUSTER_QUERY; both may list several names.
  defp parse_dns(discovery, dns_cluster_query) do
    case blank_to_nil(discovery) do
      nil -> split(dns_cluster_query || "")
      "dns:" <> names -> names |> split() |> Enum.map(&(&1 |> String.split(":") |> hd()))
      other -> fail("PORTHOLE_DISCOVERY must be dns:<name>, got: #{inspect(other)}")
    end
  end

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

  defp split(value), do: value |> String.split([",", " "], trim: true) |> Enum.map(&String.trim/1)

  defp blank_to_nil(nil), do: nil
  defp blank_to_nil(value), do: if(String.trim(value) == "", do: nil, else: value)

  defp fail(message), do: raise(ArgumentError, "Porthole sidecar: " <> message)
end

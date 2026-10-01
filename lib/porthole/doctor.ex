defmodule Porthole.Doctor do
  @moduledoc """
  Checks that Porthole can observe each node, and says what to fix when it
  cannot. Run it with `mix porthole.doctor`.

  For every node: is it reachable, which OTP and Elixir it runs (the node
  needs OTP 27+ and Elixir, but not Porthole), the round-trip latency, and
  whether a real (small) collection succeeds.
  """

  alias Porthole.Collector

  @type check :: %{
          node: String.t(),
          status: :ok | :warning | :error,
          otp: String.t() | nil,
          elixir: String.t() | nil,
          latency_ms: non_neg_integer() | nil,
          collect_ms: non_neg_integer() | nil,
          problems: [String.t()]
        }

  @timeout 5_000

  @doc "Checks every node in `nodes` (default: this node and every connected one)."
  @spec check([node()]) :: [check()]
  def check(nodes \\ [node() | Node.list()]), do: Enum.map(nodes, &check_node/1)

  defp check_node(node) do
    base = %{
      node: Atom.to_string(node),
      otp: nil,
      elixir: nil,
      latency_ms: nil,
      collect_ms: nil
    }

    case timed(fn -> remote(node, :erlang, :node, []) end) do
      {{:ok, _}, latency} ->
        # Only OTP calls: the node does not need Porthole.
        facts = %{
          otp: remote_value(node, :erlang, :system_info, [:otp_release]),
          elixir:
            case remote(node, :application, :get_key, [:elixir, :vsn]) do
              {:ok, {:ok, vsn}} -> List.to_string(vsn)
              _ -> nil
            end
        }

        {collect_ms, collect_problem} = try_collect(node)

        base
        |> Map.merge(facts)
        |> Map.merge(%{latency_ms: latency, collect_ms: collect_ms})
        |> judge(collect_problem)

      {{:error, reason}, _} ->
        Map.merge(base, %{status: :error, problems: [unreachable(node, reason)]})
    end
  end

  defp judge(check, collect_problem) do
    problems =
      Enum.reject(
        [
          check.elixir == nil &&
            "this node does not run Elixir (Porthole observes Elixir applications)",
          check.otp && String.to_integer(check.otp) < 27 &&
            "OTP #{check.otp}: Porthole needs OTP 27+",
          # Already explained by the problems above.
          check.elixir != nil && collect_problem
        ],
        &(&1 in [nil, false])
      )

    status = if problems == [], do: :ok, else: :error
    Map.merge(check, %{status: status, problems: problems})
  end

  defp try_collect(node) do
    case timed(fn ->
           Collector.collect(
             [node],
             ["system"],
             nil,
             %{max_rows: 1, max_bytes: 100_000},
             @timeout
           )
         end) do
      {{_ok, []}, ms} -> {ms, nil}
      {{_ok, [{_node, message}]}, ms} -> {ms, "collection failed: #{message}"}
    end
  end

  defp remote(node, m, f, a) do
    {:ok, :erpc.call(node, m, f, a, @timeout)}
  catch
    kind, reason -> {:error, {kind, reason}}
  end

  defp remote_value(node, m, f, a) do
    case remote(node, m, f, a) do
      {:ok, value} when is_list(value) -> List.to_string(value)
      {:ok, nil} -> nil
      {:ok, value} -> to_string(value)
      {:error, _} -> nil
    end
  end

  defp timed(fun) do
    {us, result} = :timer.tc(fun)
    {result, div(us, 1_000)}
  end

  defp unreachable(node, reason) do
    hint =
      case reason do
        {:error, {:erpc, :noconnection}} ->
          "check the node name (#{node}), that epmd (port 4369) and the distribution port are " <>
            "reachable, that both sides use the same cookie, and -sname vs -name"

        {:error, {:erpc, :timeout}} ->
          "the node did not answer in #{@timeout}ms; it may be overloaded"

        other ->
          inspect(other)
      end

    "not reachable: #{hint}"
  end

  @doc "Formats checks as a text report."
  @spec format([check()]) :: String.t()
  def format(checks) do
    Enum.map_join(checks, "\n\n", fn check ->
      mark = %{ok: "✓", warning: "!", error: "✗"}[check.status]

      facts =
        [
          check.otp && "OTP #{check.otp}",
          check.elixir && "Elixir #{check.elixir}",
          check.latency_ms && "latency #{check.latency_ms}ms",
          check.collect_ms && "collection #{check.collect_ms}ms"
        ]
        |> Enum.filter(& &1)
        |> Enum.join(", ")

      problems = Enum.map_join(check.problems, "", &"\n    - #{&1}")
      "#{mark} #{check.node}  #{facts}#{problems}"
    end)
  end
end

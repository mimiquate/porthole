defmodule Porthole.Doctor do
  @moduledoc """
  Checks that Porthole can observe each node, and says what to fix when it
  cannot. Run it with `mix porthole.doctor`.

  For every node: is it reachable, is Porthole loaded and at which version
  (compared with the querying node), which OTP and Elixir it runs, the
  round-trip latency, and whether a real (small) collection succeeds.
  """

  alias Porthole.Collector

  @type check :: %{
          node: String.t(),
          status: :ok | :warning | :error,
          porthole: String.t() | nil,
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
      porthole: nil,
      otp: nil,
      elixir: nil,
      latency_ms: nil,
      collect_ms: nil
    }

    case timed(fn -> remote(node, :erlang, :node, []) end) do
      {{:ok, _}, latency} ->
        facts = %{
          porthole: remote_value(node, Porthole.Collector, :version, []),
          otp: remote_value(node, :erlang, :system_info, [:otp_release]),
          elixir: remote_value(node, System, :version, [])
        }

        # Without Porthole on the node, a collection can only repeat that.
        {collect_ms, collect_problem} = if facts.porthole, do: try_collect(node), else: {nil, nil}

        base
        |> Map.merge(facts)
        |> Map.merge(%{latency_ms: latency, collect_ms: collect_ms})
        |> judge(collect_problem)

      {{:error, reason}, _} ->
        Map.merge(base, %{status: :error, problems: [unreachable(node, reason)]})
    end
  end

  defp judge(check, collect_problem) do
    local = Collector.version()

    problems =
      Enum.reject(
        [
          check.porthole == nil &&
            "Porthole is not loaded: add {:porthole, ...} to this node's release",
          check.porthole && check.porthole != local &&
            "Porthole #{check.porthole} here, #{local} on the querying node: use the same version",
          check.otp && String.to_integer(check.otp) < 27 &&
            "OTP #{check.otp}: Porthole needs OTP 27+",
          collect_problem
        ],
        &(&1 in [nil, false])
      )

    status =
      cond do
        collect_problem != nil or check.porthole == nil -> :error
        problems != [] -> :warning
        true -> :ok
      end

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
          check.porthole && "porthole #{check.porthole}",
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

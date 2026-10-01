defmodule Porthole.RemoteTest do
  @moduledoc """
  Collection by evaluation, against a peer node like an ordinary Elixir app
  that does not depend on Porthole: Elixir on its code path, no Porthole.
  """
  use ExUnit.Case, async: false

  alias Porthole.{Collector, Remote, Table}
  alias Porthole.Tables.Processes

  # The processes table, read on `node` by evaluation and shaped here.
  defp collect_remote(node, max_rows, budget) do
    {name, args} = Processes.gather(%{max_rows: max_rows, call_timeout: 1_000})
    with {:ok, raw} <- Remote.run(node, name, args, budget), do: {:ok, Processes.shape(raw)}
  end

  setup_all do
    unless Node.alive?() do
      System.cmd("epmd", ["-daemon"])

      {:ok, _} =
        :net_kernel.start(:"porthole_remote_#{System.unique_integer([:positive])}", %{
          name_domain: :shortnames
        })
    end

    # Only Elixir's own libraries on the peer's code path, not Porthole's.
    elixir_paths =
      for path <- :code.get_path(), to_string(path) =~ ~r{/elixir/ebin$|/logger/ebin$}, do: path

    {:ok, peer, node} =
      :peer.start(%{name: :peer.random_name(), args: Enum.flat_map(elixir_paths, &[~c"-pa", &1])})

    {:ok, _} = :erpc.call(node, :application, :ensure_all_started, [:elixir])
    on_exit(fn -> :peer.stop(peer) end)

    probe = :erpc.call(node, :erlang, :spawn, [:timer, :sleep, [:infinity]])
    true = :erpc.call(node, :erlang, :register, [:probe_proc, probe])
    %{node: node, probe: probe}
  end

  test "the peer has Elixir but no Porthole", %{node: node} do
    # Available (modules load on first use, so "loaded" would depend on order).
    assert :erpc.call(node, :code, :which, [Enum]) != :non_existing

    for module <- [Porthole.Gather, Porthole.Collector] do
      assert :erpc.call(node, :code, :which, [module]) == :non_existing
    end
  end

  test "collects processes from a node without Porthole", %{node: node, probe: probe} do
    assert {:ok, {rows, false}} = collect_remote(node, 50_000, 5_000)

    assert %{pid: pid, registered_name: "probe_proc", current_function: ":timer.sleep/1"} =
             Enum.find(rows, &(&1.registered_name == "probe_proc"))

    # Pids render as the owning node sees them, not with this node's index.
    assert pid ==
             "#PID<0." <>
               (probe
                |> :erlang.pid_to_list()
                |> to_string()
                |> String.split(".", parts: 2)
                |> List.last())

    assert %{application: "kernel"} = Enum.find(rows, &(&1.registered_name == "code_server"))

    # Nothing was left loaded on the node.
    refute :erpc.call(node, :code, :is_loaded, [Porthole.Gather])
  end

  test "the collecting processes are not in the results", %{node: node} do
    {:ok, {rows, _}} = collect_remote(node, 50_000, 5_000)
    refute Enum.any?(rows, &(&1.initial_call == ":erpc.execute_call/4"))
  end

  test "rows match the compiled collector on stable fields" do
    {:ok, {remote, _}} = collect_remote(node(), 50_000, 5_000)
    {compiled, _} = Table.collect(Processes, %{max_rows: 50_000, call_timeout: 1_000})

    stable = fn rows ->
      for row <- rows,
          row.registered_name in ["code_server", "application_controller", "kernel_sup", "logger"],
          into: %{},
          do:
            {row.registered_name,
             Map.take(row, [:pid, :initial_call, :application, :ancestors, :status])}
    end

    assert map_size(stable.(remote)) == 4
    assert stable.(remote) == stable.(compiled)
  end

  test "the deadline is enforced on the node: the worker is killed there", %{node: node} do
    # Enough processes that collecting them takes longer than 1 ms.
    many =
      for _ <- 1..30_000, do: :erpc.call(node, :erlang, :spawn, [:timer, :sleep, [:infinity]])

    before = :erpc.call(node, :erlang, :system_info, [:process_count])

    assert {:error, :timeout} = collect_remote(node, 50_000, 1)

    Process.sleep(100)
    assert :erpc.call(node, :erlang, :system_info, [:process_count]) <= before
    Enum.each(many, &:erpc.call(node, :erlang, :exit, [&1, :kill]))
  end

  # Applications forward crash logs to error trackers: a failed collection
  # must come back as a query error, never as a crash on their node. (Run on
  # this node, where the log can be captured.)
  test "a failing collection is returned as an error, without crash logs", %{node: node} do
    # An invalid process_info item makes the worker raise.
    {result, log} =
      ExUnit.CaptureLog.with_log(fn ->
        result = Remote.run(node(), :processes, [[:not_an_item], 10], 5_000)
        Process.sleep(100)
        result
      end)

    assert {:error, {:error, :badarg}} = result
    assert log == ""

    # The same on a node without Porthole, by evaluation.
    assert {:error, {:error, :badarg}} = Remote.run(node, :processes, [[:not_an_item], 10], 5_000)

    assert {:error, {:error, :badarg}} =
             Porthole.Gather.with_deadline(fn _caller -> :erlang.error(:badarg) end, [], 5_000)
  end

  test "maximum rows still apply", %{node: node} do
    assert {:ok, {[_, _, _], true}} = collect_remote(node, 3, 5_000)
  end

  test "every table collects from a node without Porthole", %{node: node} do
    names = Enum.map(Table.all(), & &1.name())
    limits = %{max_rows: 50_000, max_bytes: 10_000_000}

    assert {%{^node => tables}, []} = Collector.collect([node], names, nil, limits, 5_000)

    for name <- names do
      assert {[_ | _], false} = tables[name], "no rows for #{name}"
    end

    assert {rows, _} = tables["supervisors"]
    assert Enum.any?(rows, &(&1.name == "kernel_sup"))
  end

  test "sampling windows work on a node without Porthole", %{node: node} do
    limits = %{max_rows: 50_000, max_bytes: 10_000_000}

    assert {%{^node => %{"processes" => {rows, false}}}, []} =
             Collector.collect([node], ["processes"], 50, limits, 5_000)

    assert Enum.all?(rows, &Map.has_key?(&1, :reductions_delta))
    assert Enum.any?(rows, &is_integer(&1.reductions_delta))
  end
end

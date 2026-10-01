defmodule Porthole.RemoteTest do
  @moduledoc """
  Collection by evaluation, against a peer node like an ordinary Elixir app
  that does not depend on Porthole: Elixir on its code path, no Porthole.
  """
  use ExUnit.Case, async: false

  alias Porthole.Tables.Processes

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
    assert {:ok, {rows, false}} = Processes.collect_remote(node, 50_000, 5_000)

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
    {:ok, {rows, _}} = Processes.collect_remote(node, 50_000, 5_000)
    refute Enum.any?(rows, &(&1.initial_call == ":erpc.execute_call/4"))
  end

  test "rows match the compiled collector on stable fields" do
    {:ok, {remote, _}} = Processes.collect_remote(node(), 50_000, 5_000)
    {compiled, _} = Processes.collect(50_000)

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

    assert {:error, :timeout} = Processes.collect_remote(node, 50_000, 1)

    Process.sleep(100)
    assert :erpc.call(node, :erlang, :system_info, [:process_count]) <= before
    Enum.each(many, &:erpc.call(node, :erlang, :exit, [&1, :kill]))
  end

  test "maximum rows still apply", %{node: node} do
    assert {:ok, {[_, _, _], true}} = Processes.collect_remote(node, 3, 5_000)
  end
end

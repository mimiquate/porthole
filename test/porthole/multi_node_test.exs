defmodule Porthole.MultiNodeTest do
  @moduledoc "Peers get Porthole but not exqlite: observed nodes only need the collector."
  use ExUnit.Case, async: false

  setup_all do
    unless Node.alive?() do
      System.cmd("epmd", ["-daemon"])

      {:ok, _} =
        :net_kernel.start(:"porthole_test_#{System.unique_integer([:positive])}", %{
          name_domain: :shortnames
        })
    end

    paths = Enum.reject(:code.get_path(), &(to_string(&1) =~ "exqlite"))
    %{observed: peer(paths), bare: peer(Enum.reject(paths, &(to_string(&1) =~ "porthole")))}
  end

  test "rows from all nodes land in one database", %{observed: observed} do
    refute :erpc.call(observed, Code, :ensure_loaded?, [Exqlite.Sqlite3])

    result =
      Porthole.query!("SELECT DISTINCT node FROM processes ORDER BY 1", nodes: [node(), observed])

    assert Enum.sort(result.rows) == Enum.sort([[to_string(node())], [to_string(observed)]])
  end

  test "sampling works on remote nodes", %{observed: observed} do
    result =
      Porthole.query!("SELECT max(reductions_delta) FROM processes",
        nodes: [to_string(observed)],
        window_ms: 50
      )

    assert [[max]] = result.rows
    assert is_integer(max)
  end

  test "a node without Porthole is reported; the others answer", %{observed: observed, bare: bare} do
    result = Porthole.query!("SELECT DISTINCT node FROM applications", nodes: [observed, bare])
    assert result.rows == [[to_string(observed)]]
    assert [%{node: node, message: "Porthole is not loaded on this node"}] = result.errors
    assert node == to_string(bare)
  end

  defp peer(paths) do
    # Not linked: setup_all runs in a short-lived process.
    {:ok, pid, node} =
      :peer.start(%{name: :peer.random_name(), args: Enum.flat_map(paths, &[~c"-pa", &1])})

    {:ok, _} = :erpc.call(node, :application, :ensure_all_started, [:elixir])
    on_exit(fn -> :peer.stop(pid) end)
    node
  end
end

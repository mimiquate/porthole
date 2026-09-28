defmodule Porthole.EvalTest do
  @moduledoc "The CLAUDE.md eval set, one query per question, against Porthole.Demo."
  use ExUnit.Case, async: false

  setup_all do
    Porthole.Demo.start()
    on_exit(&Porthole.Demo.stop/0)
    Process.sleep(200)
    :ok
  end

  defp first(sql, opts \\ []), do: sql |> Porthole.query!(opts) |> Porthole.Result.maps() |> hd()

  test "1. which GenServer is serializing calls" do
    top =
      first("""
      SELECT target.registered_name, target.message_queue_len, count(*) AS blocked_callers
      FROM processes caller
      JOIN processes target ON target.node = caller.node AND target.pid = caller.waiting_on
      GROUP BY target.pid
      ORDER BY blocked_callers DESC LIMIT 1
      """)

    assert %{"registered_name" => "Shop.Pricing", "blocked_callers" => 10} = top
  end

  test "2. what is leaking memory, and on which node" do
    top =
      first(
        "SELECT node, registered_name, binary_memory_delta FROM processes ORDER BY 3 DESC LIMIT 1",
        window_ms: 300
      )

    assert %{"registered_name" => "Shop.Analytics"} = top
    assert top["node"] == to_string(node())
  end

  test "3. which supervisor is restart-looping, and what are its children" do
    top =
      first(
        """
        SELECT s.name, p.reductions_delta FROM processes p
        JOIN (SELECT DISTINCT node, pid, name FROM supervisors) s ON s.node = p.node AND s.pid = p.pid
        ORDER BY p.reductions_delta DESC LIMIT 1
        """,
        window_ms: 300
      )

    assert top["name"] == "Shop.Payments.Supervisor"

    children =
      Porthole.query!(
        "SELECT child_id FROM supervisors WHERE name = 'Shop.Payments.Supervisor' ORDER BY 1"
      )

    assert children.rows == [["Shop.Payments.Gateway"], ["Shop.Payments.Ledger"]]
  end

  test "4. largest mailboxes, grouped by what spawned them" do
    top =
      first(
        "SELECT initial_call, sum(message_queue_len) AS queued FROM processes GROUP BY 1 ORDER BY 2 DESC LIMIT 1"
      )

    assert %{"initial_call" => "Shop.Notifications.init/1"} = top
  end

  test "5. fastest-growing ETS tables over a window, and their owners" do
    top =
      first(
        """
        SELECT e.name, e.size_delta, p.registered_name AS owner FROM ets_tables e
        JOIN processes p ON p.node = e.node AND p.pid = e.owner
        ORDER BY e.size_delta DESC LIMIT 1
        """,
        window_ms: 300
      )

    assert %{"name" => "shop_search_index", "owner" => "Shop.Search.Indexer"} = top
  end

  test "6. most reductions over a window" do
    top =
      first("SELECT registered_name FROM processes ORDER BY reductions_delta DESC LIMIT 1",
        window_ms: 300
      )

    assert top["registered_name"] == "Shop.Inventory.Sync"
  end

  test "7. orphans: no links, no monitors, not supervised" do
    orphans =
      Porthole.query!("""
      SELECT registered_name FROM processes
      WHERE application = 'shop'
        AND links_count = 0 AND monitors_count = 0 AND monitored_by_count = 0
        AND pid NOT IN (SELECT child_pid FROM supervisors WHERE child_pid IS NOT NULL)
      """)

    assert orphans.rows == [["shop_import_watcher"]]
  end

  test "8. which application's processes use the most memory" do
    result =
      Porthole.query!("""
      SELECT application, sum(memory) AS bytes FROM processes
      WHERE application IS NOT NULL GROUP BY 1 ORDER BY 2 DESC
      """)

    names = Enum.map(result.rows, &hd/1)
    assert "shop" in names
    assert "kernel" in names
  end

  # Beyond the original eval set.

  test "is any VM limit getting close?" do
    top =
      first("""
      SELECT node, 1.0 * process_count / process_limit AS processes,
             1.0 * atom_count / atom_limit AS atoms,
             1.0 * port_count / port_limit AS ports,
             run_queue, schedulers_online
      FROM system
      """)

    assert top["processes"] < 0.5
    assert top["node"] == to_string(node())
  end

  test "who is leaking sockets?" do
    top =
      first("""
      SELECT p.registered_name, count(*) AS sockets
      FROM ports s JOIN processes p ON p.node = s.node AND p.pid = s.owner
      WHERE s.name IN ('tcp_inet', 'udp_inet')
      GROUP BY p.pid ORDER BY sockets DESC LIMIT 1
      """)

    assert %{"registered_name" => "Shop.Metrics.Reporter"} = top
    assert top["sockets"] >= 10
  end
end

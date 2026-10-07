defmodule Porthole.QueryTest do
  use ExUnit.Case, async: false

  alias Porthole.{Error, Policy, Result}

  test "joins across tables" do
    result =
      Porthole.query!("""
      SELECT e.name, p.registered_name FROM ets_tables e
      JOIN processes p ON p.node = e.node AND p.pid = e.owner
      WHERE e.name = 'ac_tab'
      """)

    assert result.rows == [["ac_tab", "application_controller"]]
    refute result.truncated
  end

  test "the collecting process is left out" do
    assert Porthole.query!("SELECT count(*) FROM processes WHERE pid = '#{inspect(self())}'").rows ==
             [[0]]
  end

  test "the schema lists every table, without collecting the ones not named" do
    result = Porthole.query!("SELECT name, sql FROM sqlite_master ORDER BY name")
    names = Enum.map(result.rows, &hd/1)

    assert names == Enum.sort(Enum.map(Porthole.Table.all(), & &1.name()))
    assert Enum.find(result.rows, &(hd(&1) == "ets_tables")) |> List.last() =~ "owner"
    assert [note] = result.notes
    assert note =~ "only the tables a query names are collected"

    # Named tables are still collected.
    assert [[n]] = Porthole.query!("SELECT count(*) FROM processes, sqlite_master LIMIT 1").rows
    assert n > 0
  end

  test "a query cannot make SQLite allocate unbounded memory" do
    for sql <- [
          "SELECT length(hex(zeroblob(900000000)))",
          # A string doubled 40 times.
          "WITH RECURSIVE r(s, n) AS (SELECT 'x', 0 UNION ALL SELECT s || s, n + 1 FROM r " <>
            "WHERE n < 40) SELECT max(length(s)) FROM r"
        ] do
      assert {:error, %Error{reason: :sql_error, message: message}} = Porthole.query(sql)
      assert message =~ "more memory than Porthole lets SQLite use"
    end

    # Ordinary queries are unaffected.
    assert [[_]] = Porthole.query!("SELECT count(*) FROM processes").rows
  end

  test "a client can narrow the nodes a server queries, never widen them" do
    server = [nodes: fn -> [node()] end]

    assert %{nodes: [_]} =
             Porthole.query!("SELECT 1", server ++ [only_nodes: [to_string(node())]])

    # An existing atom that names another node, outside the server's set.
    assert {:error, %Error{reason: :not_allowed}} =
             Porthole.query("SELECT 1", server ++ [only_nodes: [to_string(:intruder@elsewhere)]])

    for bad <- ["x", 42, %{"a" => 1}] do
      assert {:error, %Error{reason: :bad_request}} =
               Porthole.query("SELECT 1", server ++ [only_nodes: bad])
    end
  end

  test "invalid SQL and writes fail before anything is collected" do
    # Traces calls to the function that walks the processes, made by this
    # test's processes and the ones they spawn (the query and its workers),
    # so other tests' queries do not count.
    :erlang.trace(self(), true, [:call, :set_on_spawn])
    :erlang.trace_pattern({Porthole.Gather, :processes, 2}, true, [:local])

    on_exit(fn -> :erlang.trace_pattern({Porthole.Gather, :processes, 2}, false, [:local]) end)

    assert {:error, %Error{reason: :sql_error}} = Porthole.query("SELECT nope FROM processes")
    assert {:error, %Error{reason: :read_only}} = Porthole.query("DELETE FROM processes")
    # Trace messages arrive asynchronously: give them time either way.
    refute_receive {:trace, _, :call, {Porthole.Gather, :processes, _}}, 200

    assert %{rows: [[_]]} = Porthole.query!("SELECT count(*) FROM processes")
    assert_receive {:trace, _, :call, {Porthole.Gather, :processes, _}}, 1_000
    :erlang.trace(self(), false, [:call, :set_on_spawn])
  end

  test "writes are denied by SQLite itself" do
    for sql <- [
          "DELETE FROM processes",
          "WITH x AS (SELECT 1) DELETE FROM processes",
          "INSERT INTO applications (name) VALUES ('x')",
          "ATTACH DATABASE 'evil.db' AS evil",
          "PRAGMA writable_schema = 1",
          "CREATE TABLE t (a)"
        ] do
      assert {:error, %Error{reason: :read_only}} = Porthole.query(sql), sql
    end

    refute File.exists?("evil.db")
  end

  test "SQL errors explain what is available" do
    assert {:error, %Error{reason: :sql_error, message: message}} =
             Porthole.query("SELECT * FROM sockets")

    assert message =~ "processes, supervisors, ets_tables, ports, applications, system"
  end

  test "_delta columns need a window" do
    assert {:error, %Error{reason: :window_required}} =
             Porthole.query("SELECT reductions_delta FROM processes")

    result = Porthole.query!("SELECT max(reductions_delta) FROM processes", window_ms: 50)
    assert [[max]] = result.rows
    assert max > 0
    assert result.window_ms == 50
  end

  test "rows that did not exist at the start of the window get NULL deltas" do
    parent = self()

    Task.start(fn ->
      Process.sleep(30)
      send(parent, {:spawned, spawn(fn -> Process.sleep(:infinity) end)})
    end)

    result = Porthole.query!("SELECT pid, memory_delta FROM processes", window_ms: 100)
    assert_received {:spawned, pid}
    assert %{"memory_delta" => nil} = Enum.find(Result.maps(result), &(&1["pid"] == inspect(pid)))
  end

  test "windows are bounded by the policy" do
    assert {:error, %Error{reason: :bad_request}} =
             Porthole.query("SELECT 1", window_ms: 10_000_000)

    assert {:error, %Error{reason: :bad_request}} = Porthole.query("SELECT 1", window_ms: 0)
  end

  test "every cut is flagged with a note" do
    result = Porthole.query!("SELECT pid FROM processes", max_result_rows: 3)
    assert length(result.rows) == 3
    assert result.truncated
    assert result.notes == ["only the first 3 rows are returned"]

    result = Porthole.query!("SELECT count(*) FROM processes", max_rows: 5)
    assert result.rows == [[5]]
    assert [note] = result.notes
    assert note =~ "processes on #{node()}: collection stopped at 5 rows"

    result = Porthole.query!("SELECT group_concat(pid || pid || pid) FROM processes")
    assert [[cell]] = result.rows
    assert byte_size(cell) <= 1_024
    assert result.notes == ["1 cells were cut to 1024 bytes"]
  end

  test "slow collections are stopped on the node, not just abandoned" do
    # Claims to be a supervisor but never answers which_children (1s timeout).
    stuck =
      spawn(fn ->
        Process.put(:"$initial_call", {:supervisor, StuckSup, 1})
        Process.sleep(:infinity)
      end)

    Process.sleep(10)

    assert {:ok, result} =
             Porthole.query("SELECT count(*) FROM supervisors",
               timeout_ms: 200,
               all_supervisors: true
             )

    assert [%{message: message}] = result.errors
    assert message =~ "took longer than 200ms and was stopped on this node"

    # The worker that was calling the stuck supervisor is gone.
    Process.sleep(50)
    assert {:monitored_by, []} = Process.info(stuck, :monitored_by)
    Process.exit(stuck, :kill)
  end

  test "runaway queries are cancelled" do
    sql = "WITH RECURSIVE c(x) AS (SELECT 1 UNION ALL SELECT x + 1 FROM c) SELECT count(*) FROM c"
    assert {:error, %Error{reason: :timeout}} = Porthole.query(sql, timeout_ms: 100)
  end

  test "policies" do
    assert {:error, %Error{reason: :not_allowed}} =
             Porthole.query("SELECT 1", policy: Policy.new(tiers: []))

    Application.put_env(:porthole, :policy, max_result_rows: 2)
    on_exit(fn -> Application.delete_env(:porthole, :policy) end)
    assert %{rows: [_, _]} = Porthole.query!("SELECT pid FROM processes", max_result_rows: 100)
  end

  test "nodes can be resolved per query, and an empty set is an error" do
    assert %{nodes: [n]} = Porthole.query!("SELECT 1", nodes: fn -> [node()] end)
    assert n == to_string(node())

    assert {:error, %Error{reason: :bad_request, message: "there are no nodes to query" <> _}} =
             Porthole.query("SELECT count(*) FROM processes", nodes: fn -> [] end)

    assert {:error, %Error{reason: :bad_request}} = Porthole.query("SELECT 1", nodes: [])
  end

  test "unknown nodes are rejected without creating atoms" do
    assert {:error, %Error{reason: :bad_request}} =
             Porthole.query("SELECT 1", nodes: ["nope_#{System.unique_integer()}@x"])
  end

  test "labels and unreachable supervisors" do
    labelled = spawn(fn -> Process.set_label({:job, 42}) && Process.sleep(:infinity) end)

    fake_supervisor =
      spawn(fn ->
        Process.put(:"$initial_call", {:supervisor, FakeSup, 1})
        Process.sleep(:infinity)
      end)

    Process.sleep(10)

    assert Porthole.query!("SELECT label FROM processes WHERE pid = '#{inspect(labelled)}'").rows ==
             [["{:job, 42}"]]

    assert Porthole.query!(
             "SELECT child_status FROM supervisors WHERE pid = '#{inspect(fake_supervisor)}'",
             all_supervisors: true
           ).rows ==
             [["unreachable"]]
  end

  test "queries emit telemetry for auditing" do
    ref = :telemetry_test.attach_event_handlers(self(), [[:porthole, :query, :stop]])
    Porthole.query!("SELECT 1")
    assert_received {[:porthole, :query, :stop], ^ref, _, %{sql: "SELECT 1", result: {:ok, _}}}
  end
end

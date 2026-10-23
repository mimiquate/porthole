defmodule Porthole.TraceRemoteTest do
  @moduledoc """
  Traces on a peer node with only Elixir (no Porthole): the trace runs by
  evaluation there, and its session is gone afterwards, however the query
  ends.
  """
  use ExUnit.Case, async: false

  @moduletag :capture_log

  setup_all do
    unless Node.alive?() do
      System.cmd("epmd", ["-daemon"])

      {:ok, _} =
        :net_kernel.start(:"porthole_test_#{System.unique_integer([:positive])}", %{
          name_domain: :shortnames
        })
    end

    elixir = for path <- :code.get_path(), to_string(path) =~ ~r{/elixir/ebin$}, do: path

    # Controlled over stdio, so the peer survives a dropped distribution
    # connection (the test drops one on purpose).
    {:ok, peer, node} =
      :peer.start(%{
        name: :peer.random_name(),
        args: Enum.flat_map(elixir, &[~c"-pa", &1]),
        connection: :standard_io
      })

    {:ok, _} = :erpc.call(node, :application, :ensure_all_started, [:elixir])
    on_exit(fn -> :peer.stop(peer) end)

    # On the peer: a registered process, and a timer sending it :tick every
    # 2 ms (from the timer server, a process that is not the caller).
    inbox = :erpc.call(node, :erlang, :spawn, [:timer, :sleep, [:infinity]])
    true = :erpc.call(node, :erlang, :register, [:trace_inbox, inbox])
    {:ok, _} = :erpc.call(node, :timer, :send_interval, [2, inbox, :tick])

    %{node: node, baseline: sessions(node)}
  end

  setup do
    previous = Application.get_env(:porthole, :policy)
    Application.put_env(:porthole, :policy, tiers: [:observe, :trace])

    on_exit(fn ->
      if previous,
        do: Application.put_env(:porthole, :policy, previous),
        else: Application.delete_env(:porthole, :policy)
    end)
  end

  defp sessions(node), do: length(:erpc.call(node, :trace, :session_info, [:all]))

  defp eventually(fun, attempts \\ 50) do
    cond do
      fun.() ->
        :ok

      attempts > 0 ->
        Process.sleep(50)
        eventually(fun, attempts - 1)

      true ->
        flunk("condition never held")
    end
  end

  defp trace_query(node, window_ms) do
    Porthole.query("SELECT tag, count(*) FROM trace_messages GROUP BY 1",
      nodes: [node],
      window_ms: window_ms,
      trace: %{messages_to: "trace_inbox"}
    )
  end

  test "traces by evaluation on a node without Porthole, and leaves nothing behind", %{
    node: node,
    baseline: baseline
  } do
    refute :erpc.call(node, :code, :is_loaded, [Porthole.Gather])

    assert {:ok, result} = trace_query(node, 300)
    assert [["tick", count]] = result.rows
    assert count > 10
    assert result.errors == []

    assert sessions(node) == baseline
    refute :erpc.call(node, :code, :is_loaded, [Porthole.Gather])
  end

  test "the trace stops when the query is abandoned", %{node: node, baseline: baseline} do
    task = Task.async(fn -> trace_query(node, 30_000) end)
    eventually(fn -> sessions(node) == baseline + 1 end)

    Task.shutdown(task, :brutal_kill)
    eventually(fn -> sessions(node) == baseline end)
  end

  test "the trace stops when the connection drops", %{node: node, baseline: baseline} do
    task = Task.async(fn -> trace_query(node, 30_000) end)
    eventually(fn -> sessions(node) == baseline + 1 end)

    true = :erlang.disconnect_node(node)

    # The query reports the node instead of failing...
    assert {:ok, %{errors: [_]}} = Task.await(task, 10_000)
    # ...and the node ended the trace by itself (checking reconnects).
    eventually(fn -> sessions(node) == baseline end)
  end

  test "a flood is stopped at the event limit", %{node: node, baseline: baseline} do
    {:ok, flood} =
      :erpc.call(node, :timer, :send_interval, [
        0,
        :erpc.call(node, :erlang, :whereis, [:trace_inbox]),
        :tock
      ])

    on_exit(fn -> :erpc.call(node, :timer, :cancel, [flood]) end)

    Application.put_env(:porthole, :policy, tiers: [:observe, :trace], max_trace_events: 1_000)

    assert {:ok, result} = trace_query(node, 10_000)
    assert Enum.sum(for [_tag, count] <- result.rows, do: count) <= 1_000
    assert [note] = result.notes
    assert note =~ "max_trace_events"
    assert sessions(node) == baseline
  end
end

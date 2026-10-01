defmodule Porthole.MultiNodeTest do
  @moduledoc """
  Peer nodes: `observed` has Porthole's code (but not exqlite), `bare` is an
  Elixir node without Porthole, `otp_only` has neither Porthole nor Elixir.
  """
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

    %{
      observed: peer(paths),
      bare: peer(Enum.reject(paths, &(to_string(&1) =~ "porthole"))),
      otp_only: peer([])
    }
  end

  test "observed nodes run no Porthole processes, even with the app started", %{
    observed: observed
  } do
    {:ok, _} = :erpc.call(observed, Application, :ensure_all_started, [:porthole])
    assert :erpc.call(observed, Process, :whereis, [Porthole.Limiter]) == nil
    assert :erpc.call(observed, Supervisor, :which_children, [Porthole.Supervisor]) == []
  end

  test "rows from all nodes land in one database", %{observed: observed} do
    refute :erpc.call(observed, Code, :ensure_loaded?, [Exqlite.Sqlite3])

    result =
      Porthole.query!("SELECT DISTINCT node FROM processes ORDER BY 1", nodes: [node(), observed])

    assert Enum.sort(result.rows) == Enum.sort([[to_string(node())], [to_string(observed)]])
  end

  test "the collector does not report itself", %{observed: observed} do
    result =
      Porthole.query!(
        "SELECT count(*) FROM processes WHERE initial_call = ':erpc.execute_call/4'",
        nodes: [observed],
        window_ms: 50
      )

    assert result.rows == [[0]]
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

  test "a node without Porthole is observed like any other", %{observed: observed, bare: bare} do
    assert :erpc.call(bare, :code, :which, [Porthole.Gather]) == :non_existing

    result =
      Porthole.query!("SELECT DISTINCT node FROM applications ORDER BY node",
        nodes: [observed, bare]
      )

    assert Enum.sort(result.rows) == Enum.sort([[to_string(observed)], [to_string(bare)]])
    assert result.errors == []
  end

  test "a node without Elixir is reported; the others answer", %{bare: bare, otp_only: otp_only} do
    result = Porthole.query!("SELECT DISTINCT node FROM processes", nodes: [bare, otp_only])

    assert result.rows == [[to_string(bare)]]
    assert [%{node: node, message: "this node does not run Elixir" <> _}] = result.errors
    assert node == to_string(otp_only)
  end

  test "doctor explains what is wrong with each node", %{bare: bare, otp_only: otp_only} do
    checks = Porthole.Doctor.check([bare, otp_only, :nobody@nowhere])

    assert [
             %{status: :ok, otp: otp, elixir: elixir, problems: []},
             %{status: :error, elixir: nil, problems: [no_elixir]},
             %{status: :error, problems: [unreachable]}
           ] = checks

    assert String.to_integer(otp) >= 27
    assert elixir == System.version()
    assert no_elixir =~ "does not run Elixir"
    assert unreachable =~ "not reachable"

    report = Porthole.Doctor.format(checks)
    assert report =~ "✓ #{bare}"
    assert report =~ "✗ #{otp_only}"
  end

  defp peer(paths) do
    # Not linked: setup_all runs in a short-lived process.
    {:ok, pid, node} =
      :peer.start(%{name: :peer.random_name(), args: Enum.flat_map(paths, &[~c"-pa", &1])})

    # The OTP-only peer has no Elixir to start.
    if paths != [], do: {:ok, _} = :erpc.call(node, :application, :ensure_all_started, [:elixir])
    on_exit(fn -> :peer.stop(pid) end)
    node
  end
end

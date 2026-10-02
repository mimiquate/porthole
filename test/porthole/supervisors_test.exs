defmodule Porthole.SupervisorsTest do
  @moduledoc """
  Finding supervisors: by default by walking the applications' supervision
  trees, and with `all_supervisors: true` by scanning every process.
  """
  # Starts children under Porthole's own supervisor.
  use ExUnit.Case, async: false

  defp supervisors(opts \\ []) do
    Porthole.query!(
      "SELECT pid, name, child_id, child_pid, child_type FROM supervisors",
      Keyword.put(opts, :max_result_rows, 100_000)
    ).rows
  end

  defp pids(rows), do: rows |> Enum.map(&hd/1) |> MapSet.new()

  test "the tree walk finds the applications' supervisors, nested ones included" do
    names = for [_pid, name | _] <- supervisors(), into: MapSet.new(), do: name
    # A top supervisor, one nested under it, and an Elixir application's.
    assert MapSet.subset?(
             MapSet.new(["kernel_sup", "logger_sup", "elixir_sup"]),
             names
           )
  end

  test "it agrees with the full scan on every supervisor it finds" do
    # Supervisors, not children: children may start or stop between queries.
    found = fn rows -> MapSet.new(rows, fn [pid, name | _] -> {pid, name} end) end
    tree = found.(supervisors())
    all = found.(supervisors(all_supervisors: true))

    assert MapSet.size(tree) > 10
    assert MapSet.subset?(tree, all)
  end

  test "only the full scan finds supervisors outside application trees" do
    test = self()

    owner =
      spawn(fn ->
        {:ok, sup} = Supervisor.start_link([{Agent, fn -> :ok end}], strategy: :one_for_one)
        send(test, {:sup, sup})
        Process.sleep(:infinity)
      end)

    assert_receive {:sup, sup}
    on_exit(fn -> Process.exit(owner, :kill) end)

    refute inspect(sup) in pids(supervisors())
    assert inspect(sup) in pids(supervisors(all_supervisors: true))
  end

  test "a child declared as a supervisor but that is not one is never called" do
    # which_children sent to an Agent would crash it.
    spec = %{
      id: :not_a_supervisor,
      start: {Agent, :start_link, [fn -> :ok end]},
      type: :supervisor
    }

    {:ok, agent} = Supervisor.start_child(Porthole.Supervisor, spec)

    on_exit(fn ->
      Supervisor.terminate_child(Porthole.Supervisor, :not_a_supervisor)
      Supervisor.delete_child(Porthole.Supervisor, :not_a_supervisor)
    end)

    rows = supervisors()
    # Listed as Porthole.Supervisor's child, never walked into.
    assert Enum.any?(rows, &match?([_, "Porthole.Supervisor", "not_a_supervisor", _, _], &1))
    refute inspect(agent) in pids(rows)
    assert Process.alive?(agent)
    assert Supervisor.which_children(Porthole.Supervisor) |> List.keyfind(:not_a_supervisor, 0)
  end
end

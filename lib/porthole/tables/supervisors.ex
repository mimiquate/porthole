defmodule Porthole.Tables.Supervisors do
  @moduledoc """
  One row per supervisor child.

  Supervisors are recognized by `$initial_call` (this covers `Supervisor`,
  `DynamicSupervisor`, `Task.Supervisor` and `:supervisor`), and asked for
  `which_children` with a short timeout, as `:observer` does. A supervisor
  that does not answer yields one row with `child_status = 'unreachable'`.

  Restart counts and strategy live in supervisor state, which would need
  `:sys.get_state/1` (the evaluate tier). To spot a restart loop, sample and
  look at the supervisor's `reductions_delta` in `processes`, or at children
  whose pid keeps changing.
  """

  @behaviour Porthole.Table

  alias Porthole.{Table, Term}

  @timeout 1_000

  @impl true
  def name, do: "supervisors"

  @impl true
  def description,
    do: "One row per supervisor child: supervisor pid/name, child id/pid/type/status."

  @impl true
  def key, do: :pid

  @impl true
  def deltas, do: []

  @impl true
  def columns do
    [
      {:pid, :text, "Supervisor pid (join with processes.pid)."},
      {:name, :text, "Supervisor registered name, if any."},
      {:module, :text,
       "Callback module (Supervisor.Default for inline and dynamic supervisors)."},
      {:child_id, :text, "Child id ('undefined' for dynamic children)."},
      {:child_pid, :text, "Child pid, NULL when not running."},
      {:child_status, :text, "running | restarting | undefined | unreachable"},
      {:child_type, :text, "worker | supervisor"}
    ]
  end

  @impl true
  def collect(max_rows) do
    supervisors()
    |> Stream.flat_map(&rows/1)
    |> Enum.take(max_rows + 1)
    |> Table.take(max_rows)
  end

  defp supervisors do
    for pid <- Process.list(),
        [{_, {:supervisor, module, _}}, {_, name}] <-
          [Process.info(pid, [{:dictionary, :"$initial_call"}, :registered_name])],
        do: %{
          pid: inspect(pid),
          module: Term.name(module),
          name: if(name == [], do: nil, else: Term.name(name)),
          ref: pid
        }
  end

  defp rows(%{ref: pid} = supervisor) do
    supervisor = Map.delete(supervisor, :ref)

    case which_children(pid) do
      {:ok, children} ->
        for {id, child, type, _modules} <- children do
          Map.merge(supervisor, %{
            child_id: if(is_atom(id), do: Term.name(id), else: Term.render(id)),
            child_pid: if(is_pid(child), do: inspect(child)),
            child_status: if(is_pid(child), do: "running", else: to_string(child)),
            child_type: Atom.to_string(type)
          })
        end

      :error ->
        [
          Map.merge(supervisor, %{
            child_id: nil,
            child_pid: nil,
            child_status: "unreachable",
            child_type: nil
          })
        ]
    end
  end

  # gen_server calls use aliases, so a late reply is dropped, not left in
  # our mailbox.
  defp which_children(pid) do
    {:ok, :gen_server.call(pid, :which_children, @timeout)}
  catch
    :exit, _ -> :error
  end
end

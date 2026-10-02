defmodule Porthole.Tables.Supervisors do
  @moduledoc """
  One row per supervisor child.

  Supervisors are found by walking each application's supervision tree,
  from its top supervisor down, so the cost depends on the number of
  supervisors rather than processes. With the `all_supervisors` query
  option, every process is scanned instead, which also finds supervisors
  started outside any application's tree, at a cost proportional to the
  number of processes (slow on large or overloaded nodes).

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

  alias Porthole.{Remote, Term}

  @impl true
  def name, do: "supervisors"

  @impl true
  def description,
    do:
      "One row per supervisor child: supervisor pid/name, child id/pid/type/status. " <>
        "Covers the applications' supervision trees; pass all_supervisors to also find " <>
        "supervisors outside them (slower)."

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
  def gather(limits) do
    name = if Map.get(limits, :all_supervisors), do: :supervisors, else: :supervision_trees
    {name, [limits.max_rows, limits.call_timeout]}
  end

  @impl true
  def shape(%{rows: rows, truncated: truncated}) do
    rows =
      for {pid, module, name, child} <- rows do
        supervisor = %{
          pid: Remote.pid(pid),
          module: Term.name(module),
          name: if(name == [], do: nil, else: Term.name(name))
        }

        Map.merge(supervisor, child_columns(child))
      end

    {rows, truncated}
  end

  defp child_columns({id, child, type, _modules}) do
    %{
      child_id: if(is_atom(id), do: Term.name(id), else: Term.render(id)),
      child_pid: if(is_pid(child), do: Remote.pid(child)),
      child_status: if(is_pid(child), do: "running", else: to_string(child)),
      child_type: Atom.to_string(type)
    }
  end

  defp child_columns(:unreachable),
    do: %{child_id: nil, child_pid: nil, child_status: "unreachable", child_type: nil}
end

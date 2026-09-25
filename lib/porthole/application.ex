defmodule Porthole.Application do
  @moduledoc false

  use Application

  # Porthole is stateless: every query collects, runs and discards. The
  # supervisor exists so future tiers (e.g. budgeted trace sessions) have a
  # home.
  @impl true
  def start(_type, _args) do
    Supervisor.start_link([], strategy: :one_for_one, name: Porthole.Supervisor)
  end
end

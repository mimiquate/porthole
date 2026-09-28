defmodule Porthole.Application do
  @moduledoc false

  use Application

  # Queries are stateless: every query collects, runs and discards. The only
  # process is the limiter, and only on nodes that run queries (with SQLite):
  # nodes that are merely observed get no Porthole processes at all.
  @impl true
  def start(_type, _args) do
    children = if Porthole.Query.available?(), do: [Porthole.Limiter], else: []
    Supervisor.start_link(children, strategy: :one_for_one, name: Porthole.Supervisor)
  end
end

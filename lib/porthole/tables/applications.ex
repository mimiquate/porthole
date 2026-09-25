defmodule Porthole.Tables.Applications do
  @moduledoc """
  One row per loaded OTP application. Join `name` with
  `processes.application`.
  """

  @behaviour Porthole.Table

  alias Porthole.Table

  @impl true
  def name, do: "applications"

  @impl true
  def description, do: "One row per loaded OTP application: version, whether it is running."

  @impl true
  def key, do: :name

  @impl true
  def deltas, do: []

  @impl true
  def columns do
    [
      {:name, :text, "Application name."},
      {:vsn, :text, "Version."},
      {:description, :text, "From the .app file."},
      {:running, :boolean, "Started (1) or only loaded (0)."}
    ]
  end

  @impl true
  def collect(max_rows) do
    running = MapSet.new(Application.started_applications(), &elem(&1, 0))
    {apps, truncated} = Table.take(Application.loaded_applications(), max_rows)

    rows =
      for {app, description, vsn} <- apps do
        %{
          name: Atom.to_string(app),
          vsn: to_string(vsn),
          description: to_string(description),
          running: MapSet.member?(running, app)
        }
      end

    {rows, truncated}
  end
end

defmodule Porthole.Tables.Applications do
  @moduledoc """
  One row per loaded OTP application. Join `name` with
  `processes.application`.
  """

  @behaviour Porthole.Table

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
  def gather(_limits), do: {:applications, []}

  @impl true
  def shape(%{loaded: loaded, running: running}) do
    running = MapSet.new(running, &elem(&1, 0))

    rows =
      for {app, description, vsn} <- loaded do
        %{
          name: Atom.to_string(app),
          vsn: to_string(vsn),
          description: to_string(description),
          running: MapSet.member?(running, app)
        }
      end

    {rows, false}
  end
end

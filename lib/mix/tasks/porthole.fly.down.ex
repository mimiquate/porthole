defmodule Mix.Tasks.Porthole.Fly.Down do
  @shortdoc "Removes the Porthole sidecar started with mix porthole.fly.up"

  @moduledoc """
  Destroys the sidecar's Fly app, with its machine, secrets and tokens:

      $ mix porthole.fly.down my-app

  The app itself is not touched: nothing was installed in it. Only an app
  running the Porthole sidecar is destroyed; anything else is refused.

  ## Options

    * `--name NAME` - the sidecar's Fly app (default: `<app>-porthole`).
    * `--yes` - do not ask for confirmation.
  """

  use Mix.Task

  alias Porthole.Fly

  @impl true
  def run(args) do
    case OptionParser.parse(args, strict: [name: :string, yes: :boolean]) do
      {opts, [app], []} -> down(opts[:name] || "#{app}-porthole", opts[:yes])
      _ -> Mix.raise("usage: mix porthole.fly.down APP [--name NAME] [--yes]")
    end
  end

  defp down(sidecar, yes?) do
    case Fly.sidecar_status(sidecar) do
      :missing ->
        Mix.shell().info("#{sidecar} does not exist: nothing to remove.")

      :other ->
        Mix.raise("#{sidecar} is not a Porthole sidecar; refusing to destroy it")

      :sidecar ->
        if yes? || Mix.shell().yes?("Destroy the Fly app #{sidecar}?") do
          Fly.run!(["apps", "destroy", sidecar, "--yes"], "could not destroy #{sidecar}")

          Mix.shell().info("""
          #{sidecar} is gone. If you connected an agent, remove it too, e.g.:

              claude mcp remove #{sidecar}
          """)
        end
    end
  end
end

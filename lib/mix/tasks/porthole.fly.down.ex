defmodule Mix.Tasks.Porthole.Fly.Down do
  @shortdoc "Removes the Porthole sidecar started with mix porthole.fly.up"

  @moduledoc """
  Destroys the sidecar's Fly app, with its machine, secrets and tokens:

      $ mix porthole.fly.down my-app

  The app itself is not touched: nothing was installed in it. Only a
  sidecar started by `mix porthole.fly.up` is destroyed: any other app,
  including a Porthole sidecar set up some other way (a team's permanent
  one), is refused. It asks you to type the sidecar's name to confirm.

  ## Options

    * `--name NAME` - the sidecar's Fly app (default: `<app>-porthole`).
    * `--yes` - do not ask for confirmation.
  """

  use Mix.Task

  alias Porthole.{Fly, Trial}

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
        Mix.raise("""
        #{sidecar} is a Porthole sidecar that was not started by mix porthole.fly.up
        (a permanent one, for instance); refusing to destroy it. Use fly apps destroy
        if you really mean to.
        """)

      status when status in [:trial, :empty] ->
        if yes? || Trial.confirmed?(sidecar) do
          Fly.run!(["apps", "destroy", sidecar, "--yes"], "could not destroy #{sidecar}")

          Mix.shell().info("""
          #{sidecar} is gone. If you connected an agent, remove it too, from the
          folder where you added it, e.g.:

              claude mcp remove #{sidecar}
          """)
        end
    end
  end
end

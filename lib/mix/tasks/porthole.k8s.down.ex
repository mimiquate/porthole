defmodule Mix.Tasks.Porthole.K8s.Down do
  @shortdoc "Removes the Porthole sidecar started with mix porthole.k8s.up"

  @moduledoc """
  Deletes what `mix porthole.k8s.up` created for a Deployment (the sidecar's
  Deployment, Secret and headless Service), with its tokens:

      $ mix porthole.k8s.down my-app --namespace shop

  The app's own objects are not touched. Only a sidecar started by `up` is
  deleted: anything else, including a Porthole sidecar set up some other way
  (a team's permanent one), is refused. It asks you to type the sidecar's
  name to confirm.

  ## Options

    * `--namespace NS`, `--context CTX` - as for `kubectl`.
    * `--name NAME` - the sidecar's name (default: `<deployment>-porthole`).
    * `--yes` - do not ask for confirmation.
  """

  use Mix.Task

  alias Porthole.{Kube, Trial}

  @switches [namespace: :string, context: :string, name: :string, yes: :boolean]

  @impl true
  def run(args) do
    case OptionParser.parse(args, strict: @switches, aliases: [n: :namespace]) do
      {opts, [deployment], []} -> down(opts[:name] || "#{deployment}-porthole", opts)
      _ -> Mix.raise("usage: mix porthole.k8s.down DEPLOYMENT [--namespace NS] [options]")
    end
  end

  defp down(sidecar, opts) do
    case Kube.sidecar_status(sidecar, opts) do
      :missing ->
        Mix.shell().info("#{sidecar} does not exist: nothing to remove.")

      :other ->
        Mix.raise("#{sidecar} is not a Porthole sidecar; refusing to delete it")

      :sidecar ->
        Mix.raise("""
        #{sidecar} is a Porthole sidecar that was not started by mix porthole.k8s.up
        (a permanent one, for instance); refusing to delete it.
        """)

      :trial ->
        if opts[:yes] || Trial.confirmed?(sidecar) do
          Kube.delete!(sidecar, opts)

          Mix.shell().info("""
          #{sidecar} is gone. If you connected an agent, remove it too, from the
          folder where you added it, e.g.:

              claude mcp remove #{sidecar}
          """)
        end
    end
  end
end

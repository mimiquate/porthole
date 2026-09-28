defmodule Mix.Tasks.Porthole.Doctor do
  @shortdoc "Checks that Porthole can observe each node"

  @moduledoc """
  Checks every node Porthole would query and explains what to fix:

      $ mix porthole.doctor --connect my_app@10.0.1.12 --cookie "$RELEASE_COOKIE" --all-nodes
      ✓ my_app@10.0.1.12  porthole 0.1.0, OTP 27, Elixir 1.18.3, latency 1ms, collection 4ms
      ✗ my_app@10.0.1.13
          - Porthole is not loaded: add {:porthole, ...} to this node's release

  Exits with status 1 if any node has an error. Takes the connection options
  in `Porthole.CLI` (`--connect`, `--cookie`, `--node`, `--all-nodes`).
  """

  use Mix.Task

  @impl true
  def run(args) do
    {opts, _rest, _parsed} = Porthole.CLI.setup!(args)

    nodes =
      case opts[:nodes] do
        nil -> [node()]
        :all -> [node() | Node.list()]
        nodes -> nodes
      end

    checks = Porthole.Doctor.check(nodes)
    Mix.shell().info(Porthole.Doctor.format(checks))

    if Enum.any?(checks, &(&1.status == :error)), do: exit({:shutdown, 1})
  end
end

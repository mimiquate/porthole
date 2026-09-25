defmodule Mix.Tasks.Porthole.Query do
  @shortdoc "Runs a read-only SQL query against a live node"

  @moduledoc """
      $ mix porthole.query "SELECT registered_name, message_queue_len FROM processes ORDER BY 2 DESC LIMIT 5"
      $ mix porthole.query --connect app@127.0.0.1 --cookie secret --window 5000 \\
          "SELECT registered_name, reductions_delta FROM processes ORDER BY 2 DESC LIMIT 5"
      $ mix porthole.query --demo "SELECT initial_call, sum(message_queue_len) FROM processes GROUP BY 1 ORDER BY 2 DESC LIMIT 3"

  Add `--json` for JSON output. See `Porthole.CLI` for the other options.
  """

  use Mix.Task

  @impl true
  def run(args) do
    {json?, args} = {"--json" in args, List.delete(args, "--json")}
    {opts, rest, _parsed} = Porthole.CLI.setup!(args)
    [sql] = rest
    outcome = Porthole.query(sql, opts)

    case {json?, outcome} do
      {true, {:ok, result}} -> Mix.shell().info(JSON.encode!(result))
      {_, outcome} -> Mix.shell().info(Porthole.format(outcome))
    end

    with {:error, _} <- outcome, do: exit({:shutdown, 1})
  end
end

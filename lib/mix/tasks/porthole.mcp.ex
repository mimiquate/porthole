defmodule Mix.Tasks.Porthole.Mcp do
  @shortdoc "Serves Porthole to agents over MCP (stdio)"

  @moduledoc """
  Serves the Porthole MCP server on stdio. Configure your agent with:

      {"mcpServers": {"porthole": {"command": "mix",
        "args": ["porthole.mcp", "--connect", "app@127.0.0.1", "--cookie", "secret"]}}}

  Run `mix compile` first: compiler output on stdout would corrupt the
  protocol. See `Porthole.CLI` for options.
  """

  use Mix.Task

  @impl true
  def run(args) do
    {opts, _rest} = Porthole.CLI.setup!(args)
    Porthole.MCP.serve(opts)
  end
end

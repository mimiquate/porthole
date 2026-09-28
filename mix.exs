defmodule Porthole.MixProject do
  use Mix.Project

  @version "0.1.0"
  @source_url "https://github.com/mimiquate/porthole"

  def project do
    [
      app: :porthole,
      version: @version,
      elixir: "~> 1.18",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      description: "Read-only SQL over a live BEAM system, built for coding agents.",
      source_url: @source_url,
      package: package(),
      docs: docs()
    ]
  end

  def application do
    [
      # :inets provides the HTTP client used by the HTTP transport tests.
      extra_applications: [:logger] ++ if(Mix.env() == :test, do: [:inets], else: []),
      mod: {Porthole.Application, []}
    ]
  end

  # The demo fixtures (deliberately misbehaving processes) are compiled in dev
  # too, so they can be started from `iex -S mix` to try queries by hand.
  defp elixirc_paths(env) when env in [:dev, :test], do: ["lib", "test/support"]
  defp elixirc_paths(_env), do: ["lib"]

  defp deps do
    [
      # Only the querying node needs the SQLite NIF. Nodes that are merely
      # observed only need the pure-Elixir collectors, so this is optional.
      {:exqlite, "~> 0.41", optional: true},
      # Only the sidecar serving MCP over HTTP needs a web server.
      {:plug, "~> 1.20", optional: true},
      {:bandit, "~> 1.12", optional: true},
      {:telemetry, "~> 1.3"},
      {:ex_doc, "~> 0.38", only: :dev, runtime: false}
    ]
  end

  defp package do
    [
      licenses: ["Apache-2.0"],
      links: %{"GitHub" => @source_url}
    ]
  end

  defp docs do
    [
      main: "readme",
      source_ref: "v#{@version}",
      extras: ["README.md", "guides/use-cases.md", "guides/cookbook.md", "guides/team-setup.md"],
      groups_for_extras: [Guides: ~r/guides\//],
      # The demo is compiled in dev (for --demo) but is not part of the package.
      filter_modules: fn module, _meta ->
        not (inspect(module) =~ ~r/^(Porthole\.Demo|Shop)(\.|$)/)
      end
    ]
  end
end

defmodule PortholeSidecar.MixProject do
  use Mix.Project

  def project do
    [
      app: :porthole_sidecar,
      version: "0.1.0",
      elixir: "~> 1.18",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      # The application needs its environment variables; tests configure
      # what they exercise explicitly.
      aliases: [test: "test --no-start"],
      releases: [
        porthole_sidecar: [
          include_executables_for: [:unix],
          applications: [porthole_sidecar: :permanent]
        ]
      ]
    ]
  end

  def application do
    [extra_applications: [:logger], mod: {PortholeSidecar.Application, []}]
  end

  defp deps do
    [
      {:porthole, path: ".."},
      {:exqlite, "~> 0.41"},
      {:plug, "~> 1.20"},
      {:bandit, "~> 1.12"}
    ]
  end
end

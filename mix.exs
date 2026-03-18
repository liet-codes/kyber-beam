defmodule KyberBeam.MixProject do
  use Mix.Project

  def project do
    [
      app: :kyber_beam,
      version: "0.2.0",
      elixir: "~> 1.14",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      test_coverage: [tool: ExCoveralls],
      preferred_cli_env: [coveralls: :test],
      aliases: aliases()
    ]
  end

  def application do
    [
      extra_applications: [:logger, :runtime_tools, :os_mon],
      mod: {KyberBeam.Application, []}
    ]
  end

  defp deps do
    [
      # HTTP / WebSocket (existing)
      {:bandit, "~> 1.10"},
      {:plug, "~> 1.15"},
      {:websock_adapter, "~> 0.5"},
      {:jason, "~> 1.4"},
      {:req, "~> 0.5"},
      {:websock, "~> 0.5"},

      # Phoenix + LiveView (Phase 2)
      {:phoenix, "~> 1.7"},
      {:phoenix_live_view, "~> 1.0"},
      {:phoenix_html, "~> 4.0"},
      {:phoenix_pubsub, "~> 2.1"},
      {:phoenix_live_dashboard, "~> 0.8"},

      # Dev/test
      {:excoveralls, "~> 0.18", only: :test}
    ]
  end

  defp aliases do
    [
      setup: ["deps.get"],
      "assets.build": ["cmd --cd assets npm run build"],
      "assets.deploy": ["cmd --cd assets npm run deploy"]
    ]
  end
end

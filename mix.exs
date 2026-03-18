defmodule KyberBeam.MixProject do
  use Mix.Project

  def project do
    [
      app: :kyber_beam,
      version: "0.1.0",
      elixir: "~> 1.14",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      test_coverage: [tool: ExCoveralls],
      preferred_cli_env: [coveralls: :test]
    ]
  end

  def application do
    [
      extra_applications: [:logger],
      mod: {KyberBeam.Application, []}
    ]
  end

  defp deps do
    [
      {:bandit, "~> 1.10"},
      {:plug, "~> 1.15"},
      {:websock_adapter, "~> 0.5"},
      {:jason, "~> 1.4"},
      {:req, "~> 0.5"},
      {:websock, "~> 0.5"},
      {:excoveralls, "~> 0.18", only: :test}
    ]
  end
end

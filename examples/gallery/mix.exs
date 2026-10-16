defmodule Gallery.MixProject do
  use Mix.Project

  def project do
    [
      app: :gallery,
      version: "0.1.0",
      elixir: "~> 1.18",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  def application do
    [mod: {Gallery.Application, []}, extra_applications: [:logger, :runtime_tools]]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_env), do: ["lib"]

  defp deps do
    [
      {:a2ui_core, path: "../../umbrella/apps/a2ui_core", override: true},
      {:a2ui_agent, path: "../../umbrella/apps/a2ui_agent"},
      {:a2ui_phoenix, path: "../../umbrella/apps/a2ui_phoenix"},
      {:phoenix, "~> 1.8"},
      {:phoenix_live_view, "~> 1.1"},
      {:phoenix_html, "~> 4.2"},
      {:phoenix_live_dashboard, "~> 0.8"},
      {:telemetry_metrics, "~> 1.0"},
      {:telemetry_poller, "~> 1.0"},
      {:bandit, "~> 1.6"},
      {:jason, "~> 1.4"},
      {:req, "~> 0.5"},
      {:lazy_html, ">= 0.1.0", only: :test},
      {:restaurant_agent, path: "../restaurant_agent", only: :test}
    ]
  end
end

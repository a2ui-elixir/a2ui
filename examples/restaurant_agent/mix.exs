defmodule RestaurantAgent.MixProject do
  use Mix.Project

  def project do
    [
      app: :restaurant_agent,
      version: "0.1.0",
      elixir: "~> 1.18",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  def application do
    [extra_applications: [:logger], mod: {RestaurantAgent.Application, []}]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_env), do: ["lib"]

  defp deps do
    [
      {:a2ui_core, path: "../../umbrella/apps/a2ui_core", override: true},
      {:a2ui_agent, path: "../../umbrella/apps/a2ui_agent"},
      {:a2ui_phoenix, path: "../../umbrella/apps/a2ui_phoenix"},
      {:bandit, "~> 1.6"},
      {:jason, "~> 1.4"},
      {:req, "~> 0.5", only: :test},
      {:mint_web_socket, "~> 1.0", only: :test}
    ]
  end
end

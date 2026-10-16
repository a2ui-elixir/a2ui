defmodule TerminalClient.MixProject do
  use Mix.Project

  def project do
    [
      app: :terminal_client,
      version: "0.1.0",
      elixir: "~> 1.18",
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  def application do
    [extra_applications: [:logger]]
  end

  defp deps do
    [
      {:a2ui_core, path: "../../umbrella/apps/a2ui_core", override: true},
      {:a2ui_agent, path: "../../umbrella/apps/a2ui_agent"},
      {:req, "~> 0.5"},
      {:mint_web_socket, "~> 1.0"},
      {:jason, "~> 1.4"},
      {:restaurant_agent, path: "../restaurant_agent", only: :test}
    ]
  end
end

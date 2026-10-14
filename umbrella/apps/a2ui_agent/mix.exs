defmodule A2UIAgent.MixProject do
  use Mix.Project

  @version "0.1.0"
  @source_url "https://github.com/a2ui-project/a2ui-elixir"

  def project do
    [
      app: :a2ui_agent,
      version: @version,
      build_path: "../../_build",
      config_path: "../../config/config.exs",
      deps_path: "../../deps",
      lockfile: "../../mix.lock",
      elixir: ">= 1.17.0",
      start_permanent: Mix.env() == :prod,
      elixirc_paths: elixirc_paths(Mix.env()),
      deps: deps(),
      package: package(),
      dialyzer: [plt_local_path: "../../priv/plts", plt_add_apps: [:mix]],
      test_coverage: [tool: ExCoveralls]
    ]
  end

  def application do
    [extra_applications: [:logger]]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      {:a2ui_core, in_umbrella: true},
      {:jason, "~> 1.4"},
      {:excoveralls, "~> 0.18", only: [:test], runtime: false}
    ]
  end

  defp package do
    [
      name: "a2ui_agent",
      description:
        "Agent-side A2UI SDK for Elixir — catalog negotiation, catalog-derived prompts and validated parsing of streamed LLM output.",
      licenses: ["Apache-2.0"],
      links: %{"GitHub" => @source_url}
    ]
  end
end

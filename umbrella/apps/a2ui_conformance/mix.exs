defmodule A2UIConformance.MixProject do
  use Mix.Project

  def project do
    [
      app: :a2ui_conformance,
      version: "0.1.0",
      build_path: "../../_build",
      config_path: "../../config/config.exs",
      deps_path: "../../deps",
      lockfile: "../../mix.lock",
      elixir: ">= 1.17.0",
      start_permanent: Mix.env() == :prod,
      elixirc_paths: elixirc_paths(Mix.env()),
      deps: deps(),
      # :ex_unit is required because the harness's Matchers are
      # assertion helpers living in lib/.
      dialyzer: [plt_local_path: "../../priv/plts", plt_add_apps: [:mix, :ex_unit]],
      test_coverage: [tool: ExCoveralls]
    ]
  end

  def cli do
    [preferred_envs: [coveralls: :test, "coveralls.detail": :test]]
  end

  def application do
    [extra_applications: [:logger]]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      {:a2ui_core, in_umbrella: true},
      {:a2ui_agent, in_umbrella: true},
      {:yamerl, "~> 0.10"},
      {:jason, "~> 1.4"},
      {:excoveralls, "~> 0.18", only: [:test], runtime: false}
    ]
  end
end

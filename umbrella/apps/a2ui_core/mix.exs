defmodule A2UICore.MixProject do
  use Mix.Project

  @version "0.1.0"
  @source_url "https://github.com/a2ui-project/a2ui-elixir"

  def project do
    [
      app: :a2ui_core,
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
      dialyzer: [plt_local_path: "../../priv/plts", plt_add_apps: [:mix, :ex_unit]],
      test_coverage: [tool: ExCoveralls]
    ]
  end

  def cli do
    [preferred_envs: [coveralls: :test, coveralls_detail: :test]]
  end

  def application do
    [extra_applications: [:logger]]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      {:jason, "~> 1.4"},
      {:stream_data, "~> 1.4", only: [:test]},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      {:excoveralls, "~> 0.18", only: [:test], runtime: false}
    ]
  end

  defp package do
    [
      name: "a2ui_core",
      description:
        "Spec-faithful, multi-version A2UI protocol engine for Elixir (v0.9.1 and v1.0).",
      licenses: ["Apache-2.0"],
      links: %{"GitHub" => @source_url, "A2UI" => "https://a2ui.org"}
    ]
  end
end

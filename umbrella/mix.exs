defmodule Umbrella.MixProject do
  use Mix.Project

  def project do
    [
      apps_path: "apps",
      version: "0.1.0",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      aliases: aliases(),
      test_coverage: [tool: ExCoveralls],
      # Shared PLT config for `mix dialyzer` run from the umbrella root
      # (which is how CI invokes it). :ex_unit is required because
      # a2ui_conformance's Matchers are test-support code in lib/.
      dialyzer: [plt_add_apps: [:mix, :ex_unit]]
    ]
  end

  def cli do
    [preferred_envs: [coveralls: :test, "coveralls.detail": :test, precommit: :test]]
  end

  defp deps do
    [
      {:excoveralls, "~> 0.18", only: [:test], runtime: false}
    ]
  end

  defp aliases do
    [
      quality: [
        "format --check-formatted",
        "credo --strict",
        "dialyzer"
      ],
      precommit: [
        "format",
        "quality",
        "coveralls --umbrella"
      ]
    ]
  end
end

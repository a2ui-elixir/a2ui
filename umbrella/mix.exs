defmodule Umbrella.MixProject do
  use Mix.Project

  @source_commit_info "[spec pinned, see ../SPEC_PIN]"

  def project do
    [
      apps_path: "apps",
      version: "0.1.0",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      aliases: aliases(),
      docs: docs(),
      # Shared PLT config for `mix dialyzer` run from the umbrella root
      # (which is how CI invokes it). :ex_unit is required because
      # a2ui_conformance's Matchers are test-support code in lib/.
      dialyzer: [plt_add_apps: [:mix, :ex_unit]]
    ]
  end

  defp deps do
    [
      {:ex_doc, "~> 0.40", only: [:dev], runtime: false},
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
        "coveralls --max-failures=0"
      ]
    ]
  end

  defp docs do
    [
      main: "readme",
      source_url: "https://github.com/a2ui-project/a2ui-elixir",
      formatters: ["html"],
      api_reference: @source_commit_info
    ]
  end
end

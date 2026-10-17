defmodule A2UIAgent.MixProject do
  use Mix.Project

  @version "0.1.1"
  @source_url "https://github.com/a2ui-elixir/a2ui"

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
      name: "A2UIAgent",
      source_url: @source_url,
      docs: docs(),
      dialyzer: [plt_local_path: "../../priv/plts", plt_add_apps: [:mix]],
      test_coverage: [tool: ExCoveralls]
    ]
  end

  def cli do
    [preferred_envs: [coveralls: :test, "coveralls.detail": :test]]
  end

  def application do
    [extra_applications: [:logger, :crypto]]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      sibling(:a2ui_core),
      {:jason, "~> 1.4"},
      {:plug, "~> 1.16", optional: true},
      {:bandit, "~> 1.12", only: :test},
      {:excoveralls, "~> 0.18", only: [:test], runtime: false},
      {:ex_doc, "~> 0.40", only: :dev, runtime: false}
    ]
  end

  # Inside this repository the sibling app is used directly. The
  # published package, and a build of it (A2UI_HEX_BUILD=1 mix hex.build),
  # depend on the Hex release instead.
  defp sibling(app) do
    if in_repository?() and System.get_env("A2UI_HEX_BUILD") in [nil, ""],
      do: {app, in_umbrella: true},
      else: {app, "~> #{@version}"}
  end

  # The conformance app is never published, so it only exists here.
  defp in_repository?, do: File.dir?(Path.expand("../a2ui_conformance", __DIR__))

  defp package do
    [
      name: "a2ui_agent",
      description:
        "Agent-side A2UI SDK for Elixir: catalog negotiation, catalog-derived prompts, " <>
          "validated parsing of streamed model output, and serving over A2A.",
      licenses: ["Apache-2.0"],
      links: %{
        "GitHub" => @source_url,
        "A2UI" => "https://a2ui.org",
        "Changelog" => "https://hexdocs.pm/a2ui_agent/changelog.html"
      },
      files: ~w(lib mix.exs README.md CHANGELOG.md LICENSE)
    ]
  end

  defp docs do
    [
      main: "readme",
      source_ref: "v#{@version}",
      source_url_pattern:
        "#{@source_url}/blob/v#{@version}/umbrella/apps/a2ui_agent/%{path}#L%{line}",
      extras: ["README.md", "guides/serving_an_agent.md", "CHANGELOG.md", "LICENSE"],
      groups_for_extras: [Guides: ~r{guides/}],
      groups_for_modules: [
        Catalogs: [
          A2UIAgent,
          A2UIAgent.CatalogConfig,
          A2UIAgent.CatalogProvider,
          A2UIAgent.CatalogResolver,
          A2UIAgent.CatalogTransformer,
          A2UIAgent.CatalogTransformer.Pruning,
          A2UIAgent.Catalogs,
          A2UIAgent.SchemaPruning
        ],
        Requests: [
          A2UIAgent.Generator,
          A2UIAgent.RequestProcessor,
          A2UIAgent.PayloadValidator,
          A2UIAgent.Format
        ],
        "Direct JSON": [
          A2UIAgent.DirectJson,
          A2UIAgent.DirectJson.Prompt,
          A2UIAgent.DirectJson.Parser,
          A2UIAgent.DirectJson.JsonReader,
          A2UIAgent.PayloadFixer
        ],
        Express: [
          A2UIAgent.Express,
          A2UIAgent.Express.Prompt,
          A2UIAgent.Express.Parser,
          A2UIAgent.Express.Compiler,
          A2UIAgent.Express.Decompiler,
          A2UIAgent.Express.Syntax,
          A2UIAgent.Express.SchemaHelper,
          A2UIAgent.Express.Catalogs,
          A2UIAgent.BlockLexer
        ],
        Skills: [
          A2UIAgent.Skill,
          A2UIAgent.SkillGenerator
        ],
        Builder: [
          A2UIAgent.Builder,
          A2UIAgent.Builder.Basic,
          A2UIAgent.Builder.Component,
          A2UIAgent.Builder.Ref,
          A2UIAgent.Builder.Binding,
          A2UIAgent.Builder.ChildList,
          A2UIAgent.Builder.FunctionCall
        ],
        Macros: [
          A2UIAgent.Macro,
          A2UIAgent.Macro.Call,
          A2UIAgent.MacroExpander
        ],
        A2A: [
          A2UIAgent.A2A,
          A2UIAgent.A2A.Agent,
          A2UIAgent.A2A.Request,
          A2UIAgent.A2A.Server,
          A2UIAgent.A2A.Plug
        ],
        "MCP and AG-UI": [
          A2UIAgent.MCP,
          A2UIAgent.AGUI
        ]
      ],
      deps: [a2ui_core: "https://hexdocs.pm/a2ui_core"]
    ]
  end
end

defmodule A2UICore.MixProject do
  use Mix.Project

  @version "0.1.0"
  @source_url "https://github.com/a2ui-elixir/a2ui"

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
      name: "A2UICore",
      source_url: @source_url,
      docs: docs(),
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
      {:jason, "~> 1.4"},
      {:stream_data, "~> 1.4", only: [:test]},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      {:excoveralls, "~> 0.18", only: [:test], runtime: false},
      {:ex_doc, "~> 0.40", only: :dev, runtime: false}
    ]
  end

  defp package do
    [
      name: "a2ui_core",
      description:
        "The A2UI protocol engine for Elixir: messages, catalogs, surface state, " <>
          "node resolution and function calls, for protocol v0.9, v0.9.1 and v1.0.",
      licenses: ["Apache-2.0"],
      links: %{
        "GitHub" => @source_url,
        "A2UI" => "https://a2ui.org",
        "Changelog" => "https://hexdocs.pm/a2ui_core/changelog.html"
      },
      files: ~w(lib priv mix.exs README.md CHANGELOG.md LICENSE)
    ]
  end

  defp docs do
    [
      main: "readme",
      source_ref: "v#{@version}",
      source_url_pattern:
        "#{@source_url}/blob/v#{@version}/umbrella/apps/a2ui_core/%{path}#L%{line}",
      extras: ["README.md", "guides/processing_messages.md", "CHANGELOG.md", "LICENSE"],
      groups_for_extras: [Guides: ~r{guides/}],
      groups_for_modules: [
        Processing: [
          A2UICore,
          A2UICore.Processor,
          A2UICore.RPC,
          A2UICore.Error,
          A2UICore.Error.Detail
        ],
        Messages: [
          A2UICore.Message,
          A2UICore.Message.Operation,
          A2UICore.Message.Operation.CreateSurface,
          A2UICore.Message.Operation.UpdateComponents,
          A2UICore.Message.Operation.UpdateDataModel,
          A2UICore.Message.Operation.DeleteSurface,
          A2UICore.Message.Operation.CallRendererFunction,
          A2UICore.Message.Operation.AgentFunctionResponse,
          A2UICore.Message.RendererToAgent,
          A2UICore.Message.Adapter,
          A2UICore.Message.AdapterRegistry
        ],
        Catalogs: [
          A2UICore.Catalog,
          A2UICore.Catalog.Basic,
          A2UICore.Catalog.Component,
          A2UICore.Catalog.Function,
          A2UICore.Catalog.RefSpec,
          A2UICore.Catalog.ReferenceMap,
          A2UICore.Functions.Basic,
          A2UICore.Functions.System,
          A2UICore.Formatter,
          A2UICore.Formatter.Default
        ],
        State: [
          A2UICore.State.Surface,
          A2UICore.State.SurfaceGroup,
          A2UICore.State.DataModel,
          A2UICore.State.Component,
          A2UICore.State.Components
        ],
        Resolution: [
          A2UICore.Resolution.NodeResolver,
          A2UICore.Resolution.Node,
          A2UICore.Resolution.Binding,
          A2UICore.Resolution.Action,
          A2UICore.Resolution.DataContext,
          A2UICore.Resolution.Binder,
          A2UICore.Expression,
          A2UICore.Accessibility
        ],
        Validation: [
          A2UICore.Validation.Config,
          A2UICore.Validation.ComponentsUpdate,
          A2UICore.Validation.Integrity,
          A2UICore.Validation.Payload,
          A2UICore.Validation.ReservedKeys,
          A2UICore.Validation.Topology,
          A2UICore.Schema,
          A2UICore.Schema.Source,
          A2UICore.Schema.ECMA262,
          A2UICore.CommonTypes
        ],
        Primitives: [
          A2UICore.Version,
          A2UICore.SemVer,
          A2UICore.Pointer,
          A2UICore.Identifier,
          A2UICore.Coerce
        ]
      ]
    ]
  end
end

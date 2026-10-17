defmodule A2UIPhoenix.MixProject do
  use Mix.Project

  @version "0.1.1"
  @source_url "https://github.com/a2ui-elixir/a2ui"

  def project do
    [
      app: :a2ui_phoenix,
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
      name: "A2UIPhoenix",
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
    [extra_applications: [:logger]]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      sibling(:a2ui_core),
      {:phoenix_live_view, "~> 1.2"},
      {:phoenix_html, "~> 4.1"},
      {:plug, "~> 1.20"},
      {:jason, "~> 1.4"},
      {:lazy_html, "~> 0.1.12", only: :test},
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
      name: "a2ui_phoenix",
      description:
        "Phoenix LiveView renderer for A2UI surfaces: the basic catalog as function " <>
          "components, two-way bindings, actions, and A2UI messages over SSE.",
      licenses: ["Apache-2.0"],
      links: %{
        "GitHub" => @source_url,
        "A2UI" => "https://a2ui.org",
        "Changelog" => "https://hexdocs.pm/a2ui_phoenix/changelog.html"
      },
      files: ~w(lib priv mix.exs README.md CHANGELOG.md LICENSE)
    ]
  end

  defp docs do
    [
      main: "readme",
      source_ref: "v#{@version}",
      source_url_pattern:
        "#{@source_url}/blob/v#{@version}/umbrella/apps/a2ui_phoenix/%{path}#L%{line}",
      extras: ["README.md", "guides/rendering_surfaces.md", "CHANGELOG.md", "LICENSE"],
      groups_for_extras: [Guides: ~r{guides/}],
      groups_for_modules: [
        Rendering: [A2UIPhoenix, A2UIPhoenix.Session, A2UIPhoenix.Live, A2UIPhoenix.Surface],
        Components: [
          A2UIPhoenix.Components,
          A2UIPhoenix.Components.Basic,
          A2UIPhoenix.Context,
          A2UIPhoenix.Inputs
        ],
        Transports: [A2UIPhoenix.Plug.SSE]
      ],
      deps: [a2ui_core: "https://hexdocs.pm/a2ui_core"]
    ]
  end
end

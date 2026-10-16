defmodule Site.ContentTest do
  @moduledoc false
  # The page's figures and names, checked against the repository they describe.
  use ExUnit.Case, async: true

  alias Site.Content

  @root Path.expand("../../..", __DIR__)
  @core Path.join(@root, "umbrella/apps/a2ui_core")

  defp json(path), do: @root |> Path.join(path) |> File.read!() |> Jason.decode!()

  defp names(%{} = map), do: Map.keys(map)
  defp names(list) when is_list(list), do: Enum.map(list, & &1["name"])

  test "the basic catalog's components and functions are those of the vendored catalogs" do
    for file <- ~w(basic_v1_0.json basic_v0_9_1.json) do
      catalog = json("umbrella/apps/a2ui_core/priv/catalogs/" <> file)
      components = for {_kind, names} <- Content.components(), name <- names, do: name
      functions = for {_kind, names} <- Content.functions(), name <- names, do: name

      assert Enum.sort(components) == Enum.sort(names(catalog["components"]))
      assert Enum.sort(functions) == Enum.sort(names(catalog["functions"]))
    end
  end

  test "the MCP catalogs are those of the vendored catalogs" do
    for entry <- Content.mcp_catalogs() do
      file =
        "umbrella/apps/a2ui_core/priv/catalogs/mcp_" <>
          String.replace(entry.version, ".", "_") <> ".json"

      catalog = json(file)

      assert Enum.sort(entry.components) == Enum.sort(names(catalog["components"] || %{}))
      assert Enum.sort(entry.functions) == Enum.sort(names(catalog["functions"] || %{}))
    end
  end

  test "each message exists in the versions the matrix says" do
    schemas = %{
      {"agent", "v0.9"} => "v0_9/server_to_client.json",
      {"renderer", "v0.9"} => "v0_9/client_to_server.json",
      {"agent", "v0.9.1"} => "v0_9_1/server_to_client.json",
      {"renderer", "v0.9.1"} => "v0_9_1/client_to_server.json",
      {"agent", "v1.0"} => "v1_0/agent_to_renderer.json",
      {"renderer", "v1.0"} => "v1_0/renderer_to_agent.json"
    }

    for message <- Content.messages(), version <- Content.versions() do
      schema = File.read!(Path.join([@core, "priv/schemas", schemas[{message.from, version}]]))
      present = schema =~ ~s("#{message.name}")

      assert present == SiteWeb.PageHTML.supports?(message, version),
             "#{message.name} in #{version}"
    end
  end

  test "the conformance table is the README's, at the pinned commit" do
    readme = File.read!(Path.join(@root, "README.md"))

    rows =
      for [_, total, run] <- Regex.scan(~r/^\| `[^`]+`[^|]*\| (\d+) \| (\d+) \|/m, readme),
          do: {String.to_integer(total), String.to_integer(run)}

    assert rows == Enum.map(Content.suites(), &{&1.total, &1.run})
    assert readme =~ "Of the 1144 upstream cases at the pinned commit (`SPEC_PIN`), 946 run"

    [_, commit] = Regex.run(~r/commit:\s*([0-9a-f]+)/, File.read!(Path.join(@root, "SPEC_PIN")))
    assert String.starts_with?(commit, Content.spec_commit())
  end

  test "the skip reasons account for every skipped case, suite by suite" do
    totals = SiteWeb.PageHTML.suite_totals()
    assert Enum.sum(Enum.map(Content.skip_reasons(), & &1.count)) == totals.skipped

    # Each suite's reasons add up to its skipped cases; a reason with no count is all of them.
    counts =
      for suite <- Content.suites(), suite.skipped, into: %{} do
        parts =
          for [_, n, what] <- Regex.scan(~r/(\d+) ([^,]+)/, suite.skipped),
              do: {String.to_integer(n), what}

        parts = if parts == [], do: [{suite.total - suite.run, suite.skipped}], else: parts
        assert Enum.sum(Enum.map(parts, &elem(&1, 0))) == suite.total - suite.run, suite.name
        {suite.name, parts}
      end

    v0_8 = for {_suite, parts} <- counts, {n, what} <- parts, what =~ "v0.8", do: n
    [protocol | _] = Content.skip_reasons()
    assert Enum.sum(v0_8) == protocol.count

    names = Enum.map(Content.suites(), & &1.name)
    for reason <- Content.skip_reasons(), suite <- reason.suites, do: assert(suite in names)
  end

  test "the modules the page names exist" do
    sources =
      @root
      |> Path.join("umbrella/apps/*/lib/**/*.ex")
      |> Path.wildcard()
      |> Enum.map_join("\n", &File.read!/1)

    modules =
      for(
        package <- Content.packages(),
        module <- package.modules,
        do: package.namespace <> "." <> module
      ) ++
        Enum.map(Content.lifecycle(), & &1.module) ++
        for(
          transport <- Content.transports(),
          String.starts_with?(transport.where, "A2UI"),
          do: transport.where
        )

    for module <- modules do
      assert sources =~ ~r/defmodule #{Regex.escape(module)} do/, "#{module} is not defined"
    end
  end

  test "the examples, the guides and the assets the page names exist" do
    for example <- Content.examples() do
      assert File.dir?(Path.join(@root, example.path))
      assert File.read!(Path.join([@root, example.path, "README.md"])) =~ command(example)
    end

    for guide <- Content.guides() do
      assert File.regular?(Path.join([@root, "umbrella/apps", guide.package, guide.path]))
    end

    for asset <- ~w(a2ui_phoenix.js a2ui_phoenix.css) do
      assert File.regular?(Path.join(@root, "umbrella/apps/a2ui_phoenix/priv/static/" <> asset))
    end
  end

  # The command that starts an example: the last line of its snippet, without the comment.
  defp command(example) do
    example.run
    |> String.trim_trailing()
    |> String.split("\n")
    |> List.last()
    |> String.split("#")
    |> hd()
    |> String.trim()
  end

  test "the hero's message names seven components, four bindings and one action" do
    assert SiteWeb.PageHTML.hero_counts() == %{components: 7, bindings: 4, actions: 1}
  end
end

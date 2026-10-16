defmodule A2UIAgent.SkillGeneratorTest do
  @moduledoc false
  use ExUnit.Case, async: true

  import A2UIAgent.Test.Fixtures, only: [catalog: 2]

  alias A2UIAgent.{Express, Skill, SkillGenerator}
  alias A2UICore.Error

  doctest SkillGenerator

  defp turn(catalog_id),
    do: [
      %{
        "version" => "v1.0",
        "createSurface" => %{
          "surfaceId" => "s",
          "components" => [%{"id" => "root", "component" => "A", "catalogId" => catalog_id}]
        }
      }
    ]

  setup_all do
    catalogs = [catalog("acme/widgets/v2", ["A"]), catalog("urn:b", ["B"])]
    {:ok, format} = Express.new(catalogs, examples: [turn("acme/widgets/v2")])
    %{format: format, catalogs: catalogs}
  end

  test "a monolithic skill holds the whole prompt once", %{format: format} do
    assert {:ok, skill} = SkillGenerator.skill(format)
    assert skill.name == "a2ui" and skill.filename == "a2ui/SKILL.md"

    assert skill.description ==
             "Generates interactive user interface components for user requests."

    assert skill.content =~ "# A2UI Express DSL Output Contract"
    assert skill.content =~ "• A(text? (static))"
    assert skill.content =~ "• B(text? (static))"
    assert [_, _] = String.split(skill.content, "### Examples:")

    assert {:ok, named} = SkillGenerator.skill(format, name: "ui", description: "Mine.")
    assert {named.name, named.description} == {"ui", "Mine."}
  end

  test "a skill set: the core skill, then one per catalog", %{format: format} do
    assert {:ok, [core, widgets, b]} = SkillGenerator.skill_set(format, core_name: "core")
    assert core.filename == "core/SKILL.md"
    assert core.content =~ "## Grammar Rules"
    assert widgets.filename == "a2ui-widgets/SKILL.md"
    assert widgets.content =~ "### Examples:"
    refute b.content =~ "### Examples:"

    assert b.description ==
             "UI component catalog signatures for urn:b. Use when building urn:b user interface components."
  end

  test "a catalog skill, with or without examples", %{format: format, catalogs: [_, b]} do
    assert {:ok, skill} = SkillGenerator.catalog_skill(format)
    assert skill.name == "a2ui-widgets"
    assert skill.content =~ "### Examples:"

    assert {:ok, plain} =
             SkillGenerator.catalog_skill(format, b,
               include_examples: false,
               name: "b",
               description: "B."
             )

    assert {plain.name, plain.description} == {"b", "B."}
    refute plain.content =~ "Examples"

    assert Skill.to_markdown(plain) =~
             "---\nname: b\ndescription: B.\n---\n\n## Positional Component Signatures"
  end

  test "examples the catalogs cannot express are an error" do
    {:ok, format} = Express.new([catalog("urn:a", ["A"])], examples: [turn("urn:nope")])
    assert {:error, %Error{}} = SkillGenerator.skill(format)
    assert {:error, %Error{}} = SkillGenerator.skill_set(format)
    assert {:error, %Error{}} = SkillGenerator.catalog_skill(format)
  end

  test "a format without examples gives skills without them" do
    {:ok, format} = Express.new([catalog("urn:a", ["A"])])
    assert {:ok, skill} = SkillGenerator.skill(format)
    refute skill.content =~ "Examples"
  end

  test "clean_name/1" do
    assert SkillGenerator.clean_name(nil) == "basic"
    assert SkillGenerator.clean_name("Plain") == "plain"
    assert SkillGenerator.clean_name("a\\b\\Forms") == "forms"
    assert SkillGenerator.clean_name("/v1") == "v1"
    assert SkillGenerator.clean_name("//") == "//"
  end
end

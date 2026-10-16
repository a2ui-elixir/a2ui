defmodule A2UIAgent.SkillTest do
  @moduledoc false
  use ExUnit.Case, async: true

  alias A2UIAgent.Skill

  doctest Skill

  defp frontmatter(skill), do: skill |> Skill.to_markdown() |> String.split("\n---\n") |> hd()

  test "a long description folds at 80 columns" do
    skill =
      Skill.new(
        "a2ui-basic",
        "UI component catalog signatures for basic. Use when building basic user interface components.",
        "x"
      )

    assert frontmatter(skill) ==
             "---\nname: a2ui-basic\ndescription: UI component catalog signatures for basic. " <>
               "Use when building basic user\n  interface components."
  end

  test "scalars YAML would read as something else are quoted" do
    for {value, written} <- [
          {"true", "'true'"},
          {"123", "'123'"},
          {"it's: odd", "'it''s: odd'"},
          {"# heading", "'# heading'"},
          {"- item", "'- item'"},
          {"ends with:", "'ends with:'"},
          {" padded", "' padded'"},
          {"café", ~S("caf\xE9")},
          {"line\nbreak \"q\" \\ \t\r", ~S("line\nbreak \"q\" \\ \t\r")},
          {"snow \u{2603} \u{1F600}", "\"snow " <> <<92>> <> "u2603 " <> <<92>> <> "U0001F600\""},
          {"", "''"}
        ] do
      assert frontmatter(Skill.new("n", value, "x")) == "---\nname: n\ndescription: #{written}"
    end
  end

  test "metadata is written below the other fields" do
    skill =
      Skill.new("n", "d", "x",
        metadata: [version: 2, tags: %{"b" => true, "a" => nil}, ratio: 0.5, extra: {1}]
      )

    assert frontmatter(skill) ==
             "---\nname: n\ndescription: d\nmetadata:\n  version: 2\n  tags:\n    a: null\n    b: true\n  ratio: 0.5\n  extra: '{1}'"

    map = Skill.new("n", "d", "x", metadata: %{"z" => false, "y" => "v"})
    assert frontmatter(map) =~ "metadata:\n  y: v\n  z: false"
    assert Skill.new("n", "d", "x", filename: "custom.md").filename == "custom.md"
  end

  @tag :tmp_dir
  test "export/2 replaces each skill's directory and leaves the rest", %{tmp_dir: dir} do
    File.mkdir_p!(Path.join(dir, "a2ui-core"))
    File.write!(Path.join([dir, "a2ui-core", "stale.md"]), "old")
    File.mkdir_p!(Path.join(dir, "other"))
    File.write!(Path.join([dir, "other", "keep.md"]), "keep")

    skills = [
      Skill.new("a2ui-core", "Core.", "# Core"),
      Skill.new("solo", "Solo.", "x", filename: "solo.md")
    ]

    assert {:ok, written} = Skill.export(skills, dir)

    assert Map.keys(written) == ["a2ui-core/SKILL.md", "solo.md"]
    assert File.read!(Path.join([dir, "a2ui-core", "SKILL.md"])) == written["a2ui-core/SKILL.md"]
    refute File.exists?(Path.join([dir, "a2ui-core", "stale.md"]))
    assert File.read!(Path.join([dir, "other", "keep.md"])) == "keep"
    assert File.exists?(Path.join(dir, "solo.md"))

    blocked = Path.join(dir, "file")
    File.write!(blocked, "")

    assert {:error, %File.Error{}} =
             Skill.export(
               [Skill.new("x", "d", "c", filename: "file/x/SKILL.md")],
               Path.join(blocked, "sub")
             )
  end
end

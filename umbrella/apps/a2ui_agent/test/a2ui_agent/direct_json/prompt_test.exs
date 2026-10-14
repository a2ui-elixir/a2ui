defmodule A2UIAgent.DirectJson.PromptTest do
  @moduledoc false
  use ExUnit.Case, async: true

  import A2UIAgent.Test.Fixtures

  alias A2UIAgent.DirectJson.{Parser, Prompt}
  alias A2UICore.Error

  # The JSON of one `### <title>:` section.
  defp section(prompt, title) do
    prompt
    |> String.split("### #{title}:\n")
    |> Enum.drop(1)
    |> Enum.map(&(&1 |> String.split("\n\n") |> hd() |> Jason.decode!()))
  end

  test "the snippet is the workflow rules, then the schemas between markers" do
    assert {:ok, prompt} = Prompt.generate([basic()])

    assert String.starts_with?(prompt, "## Workflow Description:\n" <> Prompt.workflow_rules())
    assert prompt =~ "\n\n---BEGIN A2UI JSON SCHEMA---\n\n### Agent to Renderer Schema:\n{"
    assert String.ends_with?(prompt, "\n\n---END A2UI JSON SCHEMA---")
    refute prompt =~ "### Examples:"

    assert [a2r] = section(prompt, "Agent to Renderer Schema")
    assert Map.has_key?(a2r["$defs"], "CreateSurfaceMessage")
    assert [common] = section(prompt, "Common Types Schema")
    assert map_size(common["$defs"]) > 0
    assert [catalog] = section(prompt, "Catalog Schema")
    assert Map.has_key?(catalog["components"], "Text")
  end

  test "examples follow the schemas, one block per turn" do
    turn = surface()
    assert {:ok, prompt} = Prompt.generate([basic()], examples: [turn, turn])

    assert [_schemas, examples] =
             String.split(prompt, "---END A2UI JSON SCHEMA---\n\n### Examples:\n")

    block = "<a2ui-json>\n" <> Parser.decompile(turn) <> "\n</a2ui-json>"
    assert examples == block <> "\n\n" <> block
    assert Prompt.examples(nil) == ""
    assert Prompt.examples([]) == ""
  end

  test "allowed messages prune the agent-to-renderer schema" do
    {:ok, pruned} = Prompt.schema_prompt([basic()], ["deleteSurface"])

    assert [a2r] = section(pruned, "Agent to Renderer Schema")
    assert a2r["oneOf"] == [%{"$ref" => "#/$defs/DeleteSurfaceMessage"}]
    refute Map.has_key?(a2r["$defs"], "CreateSurfaceMessage")
  end

  test "each catalog gets a section; v0.9 catalogs get the v0.9 schemas" do
    {:ok, prompt} = Prompt.schema_prompt([basic_v09(), catalog("extra", ["Card"], "v0.9.1")])

    assert [a2r] = section(prompt, "Agent to Renderer Schema")
    refute Map.has_key?(a2r["$defs"], "CallRendererFunctionMessage")
    assert length(section(prompt, "Catalog Schema")) == 2
  end

  test "the catalogs must exist and share a protocol version" do
    assert {:error,
            %Error{category: :catalog, message: "The schema prompt needs at least one catalog."}} =
             Prompt.generate([])

    assert {:error, %Error{category: :catalog, message: message}} =
             Prompt.schema_prompt([basic(), basic_v09()])

    assert message =~ "different protocol versions"

    # v0.9 and v0.9.1 publish different schemas.
    assert {:error, %Error{category: :catalog}} =
             Prompt.schema_prompt([basic_v09(), catalog("extra", ["Card"], "v0.9")])
  end
end

defmodule A2UIAgent.Express.PromptTest do
  @moduledoc false
  use ExUnit.Case, async: true

  import A2UIAgent.Test.Fixtures, only: [basic_id: 0, catalog: 2]

  alias A2UIAgent.Express.{Catalogs, Prompt}
  alias A2UICore.{Catalog, Error}

  setup_all do
    {:ok, basic} = Catalogs.new([Catalog.Basic.catalog("v1.0")])

    {:ok, multi} =
      Catalogs.new([catalog("urn:a", ["Text", "Badge"]), catalog("urn:b", ["Text", "Chip"])])

    %{basic: basic, multi: multi}
  end

  defp turn(text),
    do: [
      %{
        "version" => "v1.0",
        "createSurface" => %{
          "surfaceId" => "main",
          "catalogId" => basic_id(),
          "components" => [%{"id" => "root", "component" => "Text", "text" => text}]
        }
      }
    ]

  test "generate/2 puts the rules, the catalog and the examples together", %{basic: basic} do
    assert {:ok, prompt} = Prompt.generate(basic, examples: [turn("Hi"), turn("Bye")])

    assert String.starts_with?(
             prompt,
             "## Workflow Description:\n# A2UI Express DSL Output Contract"
           )

    assert prompt =~ "\n\n## Positional Component Signatures\n"
    assert prompt =~ "• Text(text, variant? (static), weight? (static))"

    assert prompt =~
             "### Examples:\n<a2ui>\nsurface(\"main\")\nroot = Text(\"Hi\")\n</a2ui>\n\n<a2ui>"

    assert {:ok, without} = Prompt.generate(basic)
    refute without =~ "### Examples:"
    assert {:ok, ^without} = Prompt.generate(basic, examples: [])
  end

  test "an example the catalogs cannot express is an error", %{basic: basic} do
    bad = [
      %{
        "version" => "v1.0",
        "createSurface" => %{
          "surfaceId" => "main",
          "components" => [%{"id" => "root", "component" => "Sparkline"}]
        }
      }
    ]

    assert {:error, %Error{category: :validation}} = Prompt.generate(basic, examples: [bad])
  end

  test "rule 15 names a component holding one child", %{basic: basic} do
    assert Prompt.base_rules(basic) =~ "    root = Card(...)"
    {:ok, plain} = Catalogs.new([catalog("urn:p", ["Zeta", "Alpha"])])
    assert Prompt.base_rules(plain) =~ "    root = Alpha(...)"

    {:ok, empty} = Catalogs.new([catalog("urn:e", [])])
    assert Prompt.base_rules(empty) =~ "    root = ComponentA(...)"
  end

  describe "allowed messages" do
    test "every rule without an allowlist", %{basic: basic} do
      rules = Prompt.base_rules(basic)
      assert rules =~ "12. To delete a user interface surface"
      assert rules =~ "10. Data model population"
    end

    test "only the rules for the allowed statements, renumbered", %{basic: basic} do
      deletion = Prompt.base_rules(basic, ["deleteSurface"])
      assert deletion =~ "1. Primitives:"
      assert deletion =~ "5. To delete a user interface surface"
      refute deletion =~ "surface("
      refute deletion =~ "Component constructors"

      data = Prompt.base_rules(basic, ["updateDataModel"])
      assert data =~ "Data model population"
      assert data =~ ~s|surface("dashboard-surface-1")|
      refute data =~ "root = "

      components = Prompt.base_rules(basic, ["updateComponents", "DeleteSurfaceMessage"])
      assert components =~ "1. Component constructors can be assigned"
      assert components =~ "\n   header = ComponentA"
      refute components =~ "single entry point"
      refute components =~ "root = Card(...)"

      creates = Prompt.base_rules(basic, ["CreateSurfaceMessage"])
      assert creates =~ "single entry point"
      assert creates =~ "root = Card(...)"
    end
  end

  describe "several catalogs" do
    test "rules name the catalogs and the shared names", %{multi: multi} do
      rules = Prompt.base_rules(multi)
      assert rules =~ "## Multiple Catalogs\n\nSeveral component catalogs are active."
      assert rules =~ "- `urn:a`\n- `urn:b`"
      assert rules =~ ~s|widget = ComponentName(..., catalogId="urn:b")|
      assert rules =~ "- Component `Text`: `urn:a`, `urn:b`"
      refute rules =~ "Badge`:"
      refute Prompt.base_rules(multi, ["deleteSurface"]) =~ "Multiple Catalogs"
    end

    test "without shared names there is no list of them" do
      {:ok, distinct} = Catalogs.new([catalog("urn:a", ["A"]), catalog("urn:b", ["B"])])
      refute Prompt.base_rules(distinct) =~ "need a `catalogId`"
    end

    test "each catalog's signatures under its own heading", %{multi: multi} do
      instructions = Prompt.catalog_instructions(multi)
      assert instructions =~ "# Catalog `urn:a`\n\n## Positional Component Signatures"
      assert instructions =~ "# Catalog `urn:b`"
      assert Prompt.catalog_instructions(multi, "urn:b") =~ "• Chip(text? (static))"
      assert Prompt.catalog_instructions(multi, "urn:x") == ""
    end
  end

  describe "signatures" do
    test "labels, descriptions, enums and the keys of maps" do
      json = ~S"""
      {"catalogId": "urn:s", "protocolVersion": "v1.0", "instructions": "Use it.\n```json\n{\"not\": \"a message\"}\n```\n```json\nnot json\n```\n```json\n{\"version\": \"1.0\", \"deleteSurface\": {}}\n```",
       "components": {
        "Widget": {"type": "object", "description": "Line one\nline two", "properties": {
          "component": {"const": "Widget"},
          "ref": {"$ref": "common_types.json#/$defs/ComponentId"},
          "flag": {"type": "boolean", "enum": [true, false, null, 1.5, [1]]},
          "loose": {"type": "object"},
          "odd": {"oneOf": [true, {"type": "string"}]},
          "config": {"type": "object", "description": "Settings.", "properties": {"a": {"description": "The a."}, "b": {}}},
          "bare": {"type": "object", "properties": {"x": {}}},
          "rows": {"type": "array", "items": {"type": "object", "properties": {"k": {}}}},
          "list": {"type": "array", "description": "Rows.", "items": {"type": "object", "properties": {"k": {"description": "K"}}}},
          "pick": {"anyOf": [{"type": "string", "enum": ["x"]}]},
          "text": {"$ref": "common_types.json#/$defs/DynamicString"}
        }, "required": ["component", "ref"]}
       },
       "functions": {"fn": {"type": "object", "description": "Does.", "properties": {"@call": {"const": "fn"}, "args": {"properties": {"a": {"description": "The a"}, "b": {}}, "required": ["a"]}}}}}
      """

      catalog = json |> Jason.decode!(objects: :ordered_objects) |> Catalog.from_json!()
      {:ok, catalogs} = Catalogs.new([catalog])
      instructions = Prompt.catalog_instructions(catalogs)

      assert instructions =~
               "• Widget(ref (component ID), flag? (static), loose? (static), odd? (static), " <>
                 "config? (static), bare? (static), rows? (static), list? (static), " <>
                 "pick? (static), text?)"

      assert instructions =~ "  - Description: Line one\n    line two"
      assert instructions =~ "  - flag: Must be one of: 'True', 'False', 'None', '1.5', '[1]'"
      refute instructions =~ "  - loose:"
      refute instructions =~ "  - odd:"
      assert instructions =~ "  - config: Settings.\n    Map keys:\n    * a - The a.\n    * b"
      assert instructions =~ "  - bare: Map with keys:\n    * x"
      assert instructions =~ "  - rows: List of maps with keys:\n    * k"
      assert instructions =~ "  - list: Rows.\n    List of maps keys:\n    * k - K"
      assert instructions =~ "  - pick: Must be one of: 'x'"
      assert instructions =~ "• fn(a, b?)\n  - Description: Does.\n  - a: The a"
      assert instructions =~ ~s|```json\n{"not": "a message"}\n```|
      assert instructions =~ "```json\nnot json\n```"
      assert instructions =~ ~s|```\n<a2ui>\ndeleteSurface("main")\n</a2ui>\n```|
    end
  end

  test "normalize_examples/3 fills in what catalog examples leave out" do
    messages = [
      %{"createSurface" => %{"components" => []}},
      %{"version" => 0.9, "updateDataModel" => %{"value" => 1}},
      %{"callFunction" => %{"call" => "f"}, "functionCallId" => "c7"},
      %{"callFunction" => %{"call" => "g", "catalogId" => "mine"}},
      %{"other" => 1}
    ]

    assert Prompt.normalize_examples(messages, "v1.0", "urn:c") == [
             %{
               "version" => "v1.0",
               "createSurface" => %{
                 "components" => [],
                 "surfaceId" => "main",
                 "catalogId" => "urn:c"
               }
             },
             %{"version" => "v0.9", "updateDataModel" => %{"value" => 1, "surfaceId" => "main"}},
             %{
               "version" => "v1.0",
               "callRendererFunction" => %{
                 "functionCallId" => "c7",
                 "callFunction" => %{"call" => "f", "catalogId" => "urn:c"}
               }
             },
             %{
               "version" => "v1.0",
               "callRendererFunction" => %{
                 "functionCallId" => "call_1",
                 "callFunction" => %{"call" => "g", "catalogId" => "mine"}
               }
             },
             %{"other" => 1}
           ]

    ordered =
      Jason.decode!(
        ~s|[{"callFunction": {"call": "f"}, "functionCallId": "c1", "version": "v1.0"}]|,
        objects: :ordered_objects
      )

    assert [%Jason.OrderedObject{} = call] = Prompt.normalize_examples(ordered, "v1.0", nil)

    assert A2UICore.KeyOrder.to_plain(call) == %{
             "version" => "v1.0",
             "callRendererFunction" => %{
               "functionCallId" => "c1",
               "callFunction" => %{"call" => "f"}
             }
           }

    assert [%{"createSurface" => %{"surfaceId" => "main"} = create}] =
             Prompt.normalize_examples(
               [%{"version" => "v1.0", "createSurface" => %{}}],
               "v1.0",
               nil
             )

    refute Map.has_key?(create, "catalogId")
  end

  test "examples/2 of nothing is empty", %{basic: basic} do
    assert Prompt.examples(basic, nil) == {:ok, ""}
    assert Prompt.rules() =~ "15. Surface targeting"
  end
end

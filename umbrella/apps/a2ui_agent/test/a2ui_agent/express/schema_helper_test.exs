defmodule A2UIAgent.Express.SchemaHelperTest do
  @moduledoc false
  use ExUnit.Case, async: true

  alias A2UIAgent.Express.SchemaHelper
  alias A2UICore.Catalog

  doctest SchemaHelper

  defp ordered_catalog(json),
    do: json |> Jason.decode!(objects: :ordered_objects) |> Catalog.from_json!()

  @document ~S"""
  {
    "catalogId": "urn:helper",
    "protocolVersion": "v1.0",
    "components": {
      "Field": {
        "type": "object",
        "allOf": [
          {"$ref": "#/$defs/Mixin"},
          {
            "properties": {
              "component": {"const": "Field"},
              "value": {"$ref": "common_types.json#/$defs/DynamicString"},
              "rules": {"type": "array", "items": {"$ref": "common_types.json#/$defs/CheckRule"}},
              "mode": {"oneOf": [{"type": "string", "enum": ["a", "b"]}, {"type": "number"}]}
            },
            "required": ["component", "value"],
            "description": "A field."
          }
        ]
      },
      "Plain": {
        "type": "object",
        "properties": {
          "component": {"const": "Plain"},
          "items": {"type": "array", "items": {"type": "object", "properties": {"label": {}, "value": {}}}},
          "self": {"$ref": "#/$defs/Loop"},
          "local": {"$ref": "#/$defs/Bound"}
        },
        "required": ["component"]
      },
      "Bare": {"type": "object", "allOf": [{"properties": {"x": {"type": "string"}}}]}
    },
    "functions": {
      "check": {
        "type": "object",
        "description": "Checks.",
        "allOf": [
          {"$ref": "#/$defs/CheckArgs"},
          {"properties": {"args": {"properties": {"extra": {"type": "number"}}, "required": ["extra"]}}}
        ],
        "properties": {"@call": {"const": "check"}, "args": {"properties": {"value": {"description": "V"}}, "required": ["value"]}}
      }
    },
    "$defs": {
      "Mixin": {"properties": {"weight": {"type": "number"}}, "description": "Mixed in.", "allOf": [{"properties": {"deep": {}}}, {"$ref": "#/$defs/Mixin"}]},
      "Loop": {"allOf": [{"$ref": "#/$defs/Loop"}]},
      "Bound": {"properties": {"@path": {"type": "string"}}},
      "CheckArgs": {"properties": {"args": {"properties": {"pattern": {"type": "string"}}}}}
    }
  }
  """

  setup_all do
    %{helper: SchemaHelper.new(ordered_catalog(@document), "v1.0")}
  end

  test "component properties in positional order, with an own check property", %{helper: helper} do
    assert helper.component_names == ["Field", "Plain", "Bare"]

    assert SchemaHelper.component_properties(helper, "Field") ==
             ["value", "rules", "mode", "weight", "deep"]

    assert SchemaHelper.component_required(helper, "Field") == ["component", "value"]
    assert SchemaHelper.check_property(helper, "Field") == "rules"
    assert SchemaHelper.check_property(helper, "Plain") == nil
    assert SchemaHelper.property_enum(helper, "Field", "mode") == ["a", "b"]
    assert SchemaHelper.component_properties(helper, "Bare") == ["x"]
    assert SchemaHelper.component_properties(helper, "Missing") == []
    assert SchemaHelper.component_required(helper, "Missing") == []
  end

  test "descriptions", %{helper: helper} do
    assert SchemaHelper.component_description(helper, "Field") == "Mixed in."
    assert SchemaHelper.component_description(helper, "Plain") == nil
    assert SchemaHelper.component_description(helper, "Missing") == nil
    assert SchemaHelper.function_description(helper, "check") == "Checks."
    assert SchemaHelper.function_description(helper, "missing") == nil
  end

  test "function parameters, from the schema and its allOf members", %{helper: helper} do
    assert SchemaHelper.function_properties(helper, "check") == ["value", "pattern", "extra"]
    assert SchemaHelper.function_required(helper, "check") == ["value", "extra"]

    assert SchemaHelper.function_property_schema(helper, "check", "extra") ==
             Jason.decode!(~s|{"type": "number"}|, objects: :ordered_objects)

    assert SchemaHelper.function_property_schema(helper, "check", "nope") == nil
    assert SchemaHelper.function_property_schema(helper, "missing", "value") == nil
    assert SchemaHelper.function_properties(helper, "missing") == []
    assert SchemaHelper.function_required(helper, "missing") == []
    assert SchemaHelper.component?(helper, "Field")
    assert SchemaHelper.function?(helper, "check")
  end

  test "admits_path?/2 follows references and combinators, and stops at cycles", %{helper: helper} do
    schema = &SchemaHelper.property_schema(helper, &1, &2)

    assert SchemaHelper.admits_path?(helper, schema.("Field", "value"))
    refute SchemaHelper.admits_path?(helper, schema.("Field", "mode"))
    refute SchemaHelper.admits_path?(helper, schema.("Plain", "self"))
    assert SchemaHelper.admits_path?(helper, schema.("Plain", "local"))
    refute SchemaHelper.admits_path?(helper, nil)
    refute SchemaHelper.admits_path?(helper, %{"$ref" => "common_types.json#/$defs/Missing"})
    refute SchemaHelper.admits_path?(helper, %{"$ref" => "other.json#/x"})
    assert SchemaHelper.property_schema(helper, "Missing", "x") == nil
  end

  test "subschema/3 finds item and property schemas", %{helper: helper} do
    items = SchemaHelper.property_schema(helper, "Plain", "items")
    item = SchemaHelper.subschema(helper, items, "items")
    assert SchemaHelper.subschema(helper, item, "label") == %Jason.OrderedObject{values: []}

    assert SchemaHelper.subschema(helper, %{"additionalProperties" => %{"type" => "x"}}, "k") ==
             %{"type" => "x"}

    assert SchemaHelper.subschema(
             helper,
             %{"$ref" => "common_types.json#/$defs/ChildList"},
             "items"
           )

    assert SchemaHelper.subschema(helper, %{"$ref" => "#/$defs/Loop"}, "items") == nil

    assert SchemaHelper.subschema(helper, %{"oneOf" => [%{"items" => %{"a" => 1}}]}, "items") ==
             %{"a" => 1}

    assert SchemaHelper.subschema(helper, nil, "items") == nil
  end

  test "action slots and option lists" do
    assert SchemaHelper.action_slot?(%{
             "allOf" => [%{"$ref" => "common_types.json#/$defs/Action"}]
           })

    refute SchemaHelper.action_slot?(%{"$ref" => "#/$defs/Action"})
    refute SchemaHelper.action_slot?(nil)

    options = %{"items" => %{"anyOf" => [%{"properties" => %{"label" => %{}, "value" => %{}}}]}}
    assert SchemaHelper.option_objects?(%{"oneOf" => [options]})
    refute SchemaHelper.option_objects?(%{"items" => %{"properties" => %{"label" => %{}}}})
    refute SchemaHelper.option_objects?(%{"items" => 1})
    refute SchemaHelper.option_objects?(nil)
  end

  test "reserved keys and common type names" do
    assert SchemaHelper.reserved_keys("v0.9") == %{path: "path", call: "call"}

    assert SchemaHelper.common_def_name("https://a2ui.org/v0_9/common_types.json#/definitions/X") ==
             "X"

    assert SchemaHelper.common_def_name(1) == nil
    assert SchemaHelper.pairs(1) == []
    assert SchemaHelper.find_enum(1) == nil
  end

  test "inherited check properties come last, and checks named in a common type count" do
    helper = SchemaHelper.new(Catalog.Basic.catalog("v0.9.1"), "v0.9.1")
    assert List.last(SchemaHelper.component_properties(helper, "TextField")) == "checks"
    assert SchemaHelper.check_property(helper, "TextField") == "checks"
  end
end

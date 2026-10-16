defmodule A2UICore.Catalog.SchemaCleanerTest do
  @moduledoc false
  use ExUnit.Case, async: true

  alias A2UICore.Catalog.{SchemaCleaner, ValidationSchema}

  @binding %{"$ref" => "#/$defs/DataBinding"}
  @call %{"$ref" => "#/$defs/FunctionCall"}

  setup_all do
    {:ok, index: SchemaCleaner.index(ValidationSchema.published_defs("v1.0"))}
  end

  defp clean(node, index), do: node |> SchemaCleaner.clean(index) |> elem(0)

  test "the index maps literal branches to the dynamic value types", %{index: index} do
    assert index.by_scalar_kind == %{
             "string" => "DynamicString",
             "number" => "DynamicNumber",
             "boolean" => "DynamicBoolean"
           }

    assert index.catch_all == "DynamicValue"
    assert Map.values(index.by_literal_shape) == ["DynamicStringList"]
    assert MapSet.member?(index.names, "DynamicStringList")
  end

  describe "keywords" do
    test "titles are dropped unless marked as authored", %{index: index} do
      node = %{
        "title" => "T",
        "properties" => %{"title" => %{"type" => "string", "title" => "inner"}},
        "enum" => [%{"title" => "kept"}]
      }

      assert clean(node, index) == %{
               "properties" => %{"title" => %{"type" => "string"}},
               "enum" => [%{"title" => "kept"}]
             }

      marked = SchemaCleaner.mark_titles(node)
      assert marked["x-a2ui-title"] == "T"
      assert marked["enum"] == [%{"title" => "kept"}]

      assert clean(marked, index) == %{
               "title" => "T",
               "properties" => %{"title" => %{"type" => "string", "title" => "inner"}},
               "enum" => [%{"title" => "kept"}]
             }

      assert SchemaCleaner.mark_titles([%{"title" => "a"}, 1]) == [%{"x-a2ui-title" => "a"}, 1]
    end

    test "null defaults and empty items are dropped, except as property names",
         %{index: index} do
      node = %{
        "default" => nil,
        "items" => %{},
        "properties" => %{"items" => %{}, "default" => %{"type" => "null"}}
      }

      assert clean(node, index) == %{
               "properties" => %{"items" => %{}, "default" => %{"type" => "null"}}
             }
    end

    test "local references are reported", %{index: index} do
      node = %{"a" => %{"$ref" => "#/$defs/Child"}, "b" => [%{"$ref" => "#/$defs/Action"}]}
      assert {^node, refs} = SchemaCleaner.clean(node, index)
      assert refs == MapSet.new(["Child", "Action"])
    end
  end

  describe "unions" do
    test "null branches leave; a single branch left merges into its parent", %{index: index} do
      node = %{"description" => "d", "anyOf" => [%{"type" => "string"}, %{"type" => "null"}]}
      assert clean(node, index) == %{"description" => "d", "type" => "string"}

      assert clean(%{"oneOf" => [true, %{"type" => "null"}]}, index) == true
    end

    test "inline dynamic value unions become references", %{index: index} do
      dynamic = fn literals -> %{"anyOf" => literals ++ [@binding, @call]} end

      assert {%{"$ref" => "#/$defs/DynamicString", "description" => "d"}, refs} =
               SchemaCleaner.clean(
                 Map.put(dynamic.([%{"type" => "string"}]), "description", "d"),
                 index
               )

      assert MapSet.member?(refs, "DynamicString")

      assert clean(dynamic.([%{"type" => "integer"}]), index) == %{
               "$ref" => "#/$defs/DynamicNumber"
             }

      assert clean(dynamic.([%{"type" => "array", "items" => %{"type" => "string"}}]), index) ==
               %{"$ref" => "#/$defs/DynamicStringList"}

      assert clean(dynamic.([%{"type" => "string"}, %{"properties" => %{}}]), index) ==
               %{"$ref" => "#/$defs/DynamicValue"}

      assert clean(dynamic.([%{"additionalProperties" => true}]), index) ==
               %{"$ref" => "#/$defs/DynamicValue"}

      wrapped_call = %{"allOf" => [@call, %{"description" => "returns a string"}]}

      assert clean(%{"oneOf" => [%{"type" => "boolean"}, @binding, wrapped_call]}, index) ==
               %{"$ref" => "#/$defs/DynamicBoolean"}
    end

    test "unions that match no dynamic value type stay", %{index: index} do
      constrained = %{"anyOf" => [%{"type" => "string", "enum" => ["a"]}, @binding, @call]}

      assert clean(constrained, index) == %{
               "oneOf" => [%{"type" => "string", "enum" => ["a"]}, @binding, @call]
             }

      unknown = %{"oneOf" => [%{"const" => 1}, @binding, @call]}
      assert clean(unknown, index) == %{"$ref" => "#/$defs/DynamicValue"}

      only_refs = %{"oneOf" => [@binding, @call]}
      assert clean(only_refs, index) == only_refs
    end

    test "anyOf becomes oneOf unless it only constrains or sits under additionalProperties",
         %{index: index} do
      assert clean(%{"anyOf" => [%{"type" => "string"}, %{"type" => "number"}]}, index) ==
               %{"oneOf" => [%{"type" => "string"}, %{"type" => "number"}]}

      constraint = %{"anyOf" => [%{"required" => ["a"]}, %{"required" => ["b"]}]}
      assert clean(constraint, index) == constraint

      additional = %{"additionalProperties" => %{"anyOf" => [%{"type" => "a"}, %{"type" => "b"}]}}
      assert clean(additional, index) == additional

      assert clean(%{"anyOf" => "odd"}, index) == %{"anyOf" => "odd"}
    end

    test "the catalog's unions keep a single branch", %{index: index} do
      node = %{"$defs" => %{"anyComponent" => %{"oneOf" => [%{"$ref" => "#/components/A"}]}}}
      assert clean(node, index) == node
    end
  end
end

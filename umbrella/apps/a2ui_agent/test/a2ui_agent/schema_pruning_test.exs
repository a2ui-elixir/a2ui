defmodule A2UIAgent.SchemaPruningTest do
  @moduledoc false
  use ExUnit.Case, async: true

  alias A2UIAgent.SchemaPruning

  doctest SchemaPruning

  describe "prune_messages/2" do
    test "an empty allowlist admits no message" do
      schema = %{
        "oneOf" => [%{"$ref" => "#/$defs/A"}],
        "$defs" => %{"A" => %{"properties" => %{"createSurface" => %{}}}}
      }

      assert SchemaPruning.prune_messages(schema, []) == %{"oneOf" => [], "$defs" => %{}}
    end

    test "without definitions the allowlist names the oneOf targets" do
      schema = %{"oneOf" => [%{"$ref" => "#/$defs/A"}, %{"$ref" => "#/$defs/B"}, %{}]}

      assert SchemaPruning.prune_messages(schema, ["B", "unknown"]) ==
               %{"oneOf" => [%{"$ref" => "#/$defs/B"}]}
    end

    test "leaves a schema without a oneOf list as it is" do
      assert SchemaPruning.prune_messages(%{"oneOf" => "x"}, []) == %{"oneOf" => "x"}
      assert SchemaPruning.prune_messages(%{}, ["createSurface"]) == %{}
    end
  end

  describe "prune_common_types/2" do
    test "keeps the definitions in use and the definitions they use" do
      common = %{
        "$id" => "common_types.json",
        "$defs" => %{
          "A" => %{"$ref" => "#/$defs/B"},
          "B" => %{"items" => [%{"$ref" => "#/$defs/C"}]},
          "C" => %{},
          "D" => %{},
          "E" => %{}
        }
      }

      referencing = [
        %{"properties" => %{"x" => %{"$ref" => "common_types.json#/$defs/A"}}},
        %{"anyOf" => [%{"$ref" => "#/$defs/E"}, %{"$ref" => "#/$defs/Missing"}]},
        %{"$ref" => "other.json"}
      ]

      assert SchemaPruning.prune_common_types(common, referencing) == %{
               "$id" => "common_types.json",
               "$defs" => Map.take(common["$defs"], ["A", "B", "C", "E"])
             }
    end

    test "a schema without definitions is kept as it is" do
      assert SchemaPruning.prune_common_types(%{}, [%{"$ref" => "#/$defs/A"}]) == %{}
      assert SchemaPruning.prune_common_types(%{"type" => "object"}, []) == %{"type" => "object"}
    end
  end
end

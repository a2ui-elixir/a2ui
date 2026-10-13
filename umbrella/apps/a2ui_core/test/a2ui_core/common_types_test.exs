defmodule A2UICore.CommonTypesTest do
  @moduledoc false
  use ExUnit.Case, async: true

  alias A2UICore.CommonTypes
  alias A2UICore.Error

  doctest CommonTypes

  test "definitions lists the version's $defs" do
    assert "Extensions" in CommonTypes.definitions("v1.0")
    refute "Extensions" in CommonTypes.definitions("v0.9.1")
    assert "FunctionCall" in CommonTypes.definitions("v0.9")
  end

  test "an unknown definition raises" do
    assert_raise ArgumentError, ~r/not a common types definition/, fn ->
      CommonTypes.validate(%{}, "NoSuchType", "v1.0")
    end
  end

  describe "dynamic_definitions/0" do
    test "names the definitions that may be bindings or calls" do
      names = CommonTypes.dynamic_definitions()

      for name <-
            ~w(DynamicString DynamicNumber DynamicBoolean DynamicStringList DynamicValue DataBinding) do
        assert MapSet.member?(names, name)
      end

      refute MapSet.member?(names, "Action")
      refute MapSet.member?(names, "ChildList")
    end
  end

  describe "function_stub/1" do
    test "v1.0 requires @call and keeps @index out" do
      stub = CommonTypes.function_stub("v1.0")

      assert stub["required"] == ["@call"]
      assert stub["properties"]["@call"]["not"] == %{"const" => "@index"}
      assert stub["properties"]["args"] == %{"type" => "object"}
      refute Map.has_key?(stub, "additionalProperties")
    end

    test "v0.9 closes the object over call, args and returnType" do
      stub = CommonTypes.function_stub("v0.9")

      assert stub["additionalProperties"] == false
      assert Map.keys(stub["properties"]) |> Enum.sort() == ["args", "call", "returnType"]
    end
  end

  describe "permissive_catalog/1" do
    test "accepts any component, theme and function shape" do
      for version <- ["v0.9", "v1.0"] do
        defs = CommonTypes.permissive_catalog(version)["$defs"]

        assert defs["anyComponent"] == %{"type" => "object", "additionalProperties" => true}
        assert defs["theme"] == true
        assert defs["anyFunction"] == CommonTypes.function_stub(version)
      end
    end
  end

  describe "the catalog-agnostic FunctionCall stub" do
    test "v1.0 accepts any named call, with or without args" do
      assert {:ok, _} = CommonTypes.validate(%{"@call" => "now"}, "FunctionCall", "v1.0")

      assert {:ok, _} =
               CommonTypes.validate(
                 %{"@call" => "x", "args" => %{"a" => 1}},
                 "FunctionCall",
                 "v1.0"
               )
    end

    test "v1.0 keeps @index exclusive to IndexSystemFunction inside DynamicValue" do
      assert {:ok, _} = CommonTypes.validate(%{"@call" => "@index"}, "DynamicValue", "v1.0")
    end

    test "v1.0 rejects unknown keys and non-object args" do
      assert {:error, %Error{category: :validation, details: [_ | _]}} =
               CommonTypes.validate(%{"@call" => "x", "bogus" => 1}, "FunctionCall", "v1.0")

      assert {:error, _} =
               CommonTypes.validate(%{"@call" => "x", "args" => 1}, "FunctionCall", "v1.0")
    end

    test "v0.9 closes the call object" do
      assert {:ok, _} =
               CommonTypes.validate(%{"call" => "x", "args" => %{}}, "FunctionCall", "v0.9")

      assert {:error, _} =
               CommonTypes.validate(%{"call" => "x", "extra" => 1}, "FunctionCall", "v0.9")
    end
  end
end

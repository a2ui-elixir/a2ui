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

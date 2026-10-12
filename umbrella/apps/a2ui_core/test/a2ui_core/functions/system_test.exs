defmodule A2UICore.Functions.SystemTest do
  @moduledoc false
  use ExUnit.Case, async: true

  alias A2UICore.Catalog.Function
  alias A2UICore.Error
  alias A2UICore.Functions.System
  alias A2UICore.Resolution.DataContext

  describe "functions/1" do
    test "v1.0 provides @index" do
      assert [%Function{name: "@index", return_type: "number", execute: execute}] =
               System.functions("v1.0")

      assert is_function(execute, 2)
    end

    test "earlier versions provide none" do
      assert System.functions("v0.9") == []
      assert System.functions("v0.9.1") == []
    end
  end

  describe "index/2" do
    test "is the offset without a context" do
      assert System.index(%{}, nil) == {:ok, 0}
      assert System.index(%{"offset" => 5}, nil) == {:ok, 5}
    end

    test "adds the collection index to the offset" do
      scope = DataContext.new() |> DataContext.nested("items/3")

      assert System.index(%{}, scope) == {:ok, 3}
      assert System.index(%{"offset" => 1}, scope) == {:ok, 4}
      assert System.index(%{"offset" => "2"}, scope) == {:ok, 5}
    end

    test "uses the explicit iteration index of the nearest scope" do
      scope = DataContext.new() |> DataContext.nested("rows", 7)

      assert System.index(%{}, scope) == {:ok, 7}
    end

    test "outside a collection scope it is an error" do
      assert {:error, %Error{category: :validation, message: message}} =
               System.index(%{}, DataContext.new())

      assert message ==
               "@index function can only be evaluated inside a collection template iteration scope."
    end

    test "a non-numeric offset is an error" do
      assert {:error, %Error{category: :validation, message: message}} =
               System.index(%{"offset" => "x"}, nil)

      assert message == ~s(@index requires a numeric offset, got "x".)
    end
  end
end

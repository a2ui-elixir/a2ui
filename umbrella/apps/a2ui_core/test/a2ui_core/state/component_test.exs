defmodule A2UICore.State.ComponentTest do
  @moduledoc false
  use ExUnit.Case, async: true

  alias A2UICore.Catalog.RefSpec
  alias A2UICore.State.{Component, Components}

  doctest A2UICore.State.Component
  doctest A2UICore.State.Components

  describe "Component" do
    test "from_wire splits id, type and props; tree puts them back" do
      wire = %{"id" => "t", "component" => "Text", "text" => "hi", "weight" => 1}
      component = Component.from_wire(wire)

      assert %Component{id: "t", type: "Text", props: %{"text" => "hi", "weight" => 1}} =
               component

      assert Component.tree(component) == wire
    end

    test "records the catalog it was created against" do
      assert Component.from_wire(%{"id" => "a", "component" => "X"}, catalog_id: "c1").catalog_id ==
               "c1"

      assert Component.new("a", "X", %{}, catalog_id: "c2").catalog_id == "c2"
      assert Component.new("a", "X").catalog_id == nil
    end

    test "tree prefers id and component over same-named props" do
      component = Component.new("real", "Real", %{"extra" => 1})
      assert Component.tree(component) == %{"id" => "real", "component" => "Real", "extra" => 1}
    end

    test "child_references uses the spec; a nil spec means no known references" do
      component = Component.new("row", "Row", %{"children" => ["a", "b"]})
      spec = RefSpec.new(list: ["children"])

      assert Component.child_references(component, spec) ==
               [{"a", "children[0]"}, {"b", "children[1]"}]

      assert Component.child_references(component, nil) == []
    end
  end

  describe "Components" do
    defp text(id), do: Component.new(id, "Text", %{"text" => id})

    test "add rejects a duplicate id with a state error" do
      {:ok, set} = Components.add(Components.new(), text("a"))

      assert {:error, error} = Components.add(set, text("a"))
      assert error.category == :state
      assert error.message == "Component with id 'a' already exists."
      assert error.path == "components.a"
    end

    test "put adds or replaces" do
      set = Components.new() |> Components.put(text("a"))
      replaced = Components.put(set, Component.new("a", "Image"))

      assert Components.get(replaced, "a").type == "Image"
      assert Components.size(replaced) == 1
    end

    test "remove is a no-op for an absent id" do
      set = Components.from_list([text("a"), text("b")])

      assert Components.remove(set, "a") |> Components.ids() == ["b"]
      assert Components.remove(set, "zzz") == set
    end

    test "get/has?/size" do
      set = Components.from_list([text("a")])

      assert Components.get(set, "a").id == "a"
      assert Components.get(set, "b") == nil
      assert Components.has?(set, "a")
      refute Components.has?(set, "b")
      assert Components.size(set) == 1
    end

    test "ids, to_list and trees are sorted by id" do
      set = Components.from_list([text("c"), text("a"), text("b")])

      assert Components.ids(set) == ["a", "b", "c"]
      assert Enum.map(Components.to_list(set), & &1.id) == ["a", "b", "c"]
      assert Enum.map(Components.trees(set), & &1["id"]) == ["a", "b", "c"]
    end

    test "from_list keeps the last component for a repeated id" do
      set = Components.from_list([text("a"), Component.new("a", "Image")])
      assert Components.get(set, "a").type == "Image"
    end
  end
end

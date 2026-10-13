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

    test "child_references follows the spec when it names child properties" do
      component = Component.new("row", "Row", %{"children" => ["a", "b"], "other" => "c"})
      spec = RefSpec.new(list: ["children"])

      assert Component.child_references(component, spec) ==
               [{"a", "children[0]"}, {"b", "children[1]"}]
    end

    test "child_references infers references without a spec" do
      component = Component.new("row", "Row", %{"children" => ["a", "b"]})
      inferred = [{"a", "children.[0]"}, {"b", "children.[1]"}]

      assert Component.child_references(component, nil) == inferred
      assert Component.child_references(component, RefSpec.new()) == inferred
    end

    test "inferred references use naming conventions" do
      component =
        Component.new("c", "Card", %{
          "contentChild" => "body",
          "headerChild" => "head",
          "template" => %{"componentId" => "item", "path" => "/items"},
          "text" => "ignored",
          "title" => "ignored"
        })

      assert Component.child_references(component, nil) == [
               {"body", "contentChild"},
               {"head", "headerChild"},
               {"item", "template.componentId"}
             ]
    end

    test "inferred references inspect values against the known ids" do
      component = Component.new("c", "Custom", %{"slot" => "known", "other" => "unknown"})

      assert Component.child_references(component, nil) == []
      assert Component.child_references(component, nil, ["known"]) == [{"known", "slot"}]

      # One known id qualifies the property; every entry then counts.
      listed = Component.new("c", "Custom", %{"slots" => ["known", "nope"]})

      assert Component.child_references(listed, nil, ["known"]) ==
               [{"known", "slots.[0]"}, {"nope", "slots.[1]"}]

      assert Component.child_references(listed, nil, []) == []

      objects =
        Component.new("c", "Custom", %{"parts" => [%{"child" => "x"}], "box" => %{"child" => "y"}})

      assert Component.child_references(objects, nil) == [
               {"y", "box.child"},
               {"x", "parts.[0].child"}
             ]
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

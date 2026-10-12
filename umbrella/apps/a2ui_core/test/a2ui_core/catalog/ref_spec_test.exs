defmodule A2UICore.Catalog.RefSpecTest do
  @moduledoc false
  use ExUnit.Case, async: true

  alias A2UICore.Catalog.RefSpec

  doctest A2UICore.Catalog.RefSpec

  describe "new/1, empty?/1, child_prop?/2" do
    test "an empty spec names no properties" do
      spec = RefSpec.new()
      assert RefSpec.empty?(spec)
      refute RefSpec.child_prop?(spec, "child")
    end

    test "single and list properties are child properties" do
      spec = RefSpec.new(single: ["child"], list: ["children"], nested: %{"tabs" => ["child"]})

      refute RefSpec.empty?(spec)
      assert RefSpec.child_prop?(spec, "child")
      assert RefSpec.child_prop?(spec, "children")
      refute RefSpec.child_prop?(spec, "label")
    end
  end

  describe "extract/2" do
    test "single properties hold one id" do
      spec = RefSpec.new(single: ["child"])
      assert RefSpec.extract(spec, %{"child" => "a"}) == [{"a", "child"}]
    end

    test "list properties report an indexed path per id" do
      spec = RefSpec.new(list: ["children"])

      assert RefSpec.extract(spec, %{"children" => ["a", "b"]}) ==
               [{"a", "children[0]"}, {"b", "children[1]"}]
    end

    test "a template object reports its componentId" do
      spec = RefSpec.new(list: ["children"])
      props = %{"children" => %{"componentId" => "row", "path" => "/items"}}

      assert RefSpec.extract(spec, props) == [{"row", "children.componentId"}]
    end

    test "nested item keys report the item path" do
      spec = RefSpec.new(list: ["tabs"], nested: %{"tabs" => ["child"]})

      props = %{
        "tabs" => [%{"title" => "One", "child" => "a"}, %{"title" => "Two", "child" => "b"}]
      }

      assert RefSpec.extract(spec, props) == [{"a", "tabs[0].child"}, {"b", "tabs[1].child"}]
    end

    test "list items that are objects with a componentId" do
      spec = RefSpec.new(list: ["children"])
      props = %{"children" => [%{"componentId" => "x"}]}

      assert RefSpec.extract(spec, props) == [{"x", "children[0].componentId"}]
    end

    test "list items that are objects with other child slots" do
      spec = RefSpec.new(list: ["children"])
      props = %{"children" => [%{"child" => "x"}]}

      assert RefSpec.extract(spec, props) == [{"x", "children[0].child"}]
    end

    test "a list property holding a bare id" do
      spec = RefSpec.new(list: ["children"])
      assert RefSpec.extract(spec, %{"children" => "only"}) == [{"only", "children"}]
    end

    test "a list property holding an object with nested slots" do
      spec = RefSpec.new(list: ["children"])
      props = %{"children" => %{"header" => "h", "footer" => "f"}}

      assert RefSpec.extract(spec, props) ==
               [{"f", "children.footer"}, {"h", "children.header"}]
    end

    test "single properties come before list properties, each in sorted key order" do
      spec = RefSpec.new(single: ["trigger", "content"], list: ["children"])
      props = %{"trigger" => "t", "content" => "c", "children" => ["x"]}

      assert RefSpec.extract(spec, props) ==
               [{"c", "content"}, {"t", "trigger"}, {"x", "children[0]"}]
    end

    test "absent, empty and non-reference values are ignored" do
      spec = RefSpec.new(single: ["child"], list: ["children"])

      assert RefSpec.extract(spec, %{}) == []
      assert RefSpec.extract(spec, %{"child" => "", "children" => []}) == []
      assert RefSpec.extract(spec, %{"child" => 42, "children" => [1, nil, true]}) == []
    end

    test "non-map props have no references" do
      assert RefSpec.extract(RefSpec.new(single: ["child"]), nil) == []
    end
  end

  describe "from_value/1" do
    test "scalars" do
      assert RefSpec.from_value("id") == [{"id", ""}]
      assert RefSpec.from_value("") == []
      assert RefSpec.from_value(nil) == []
      assert RefSpec.from_value(7) == []
      assert RefSpec.from_value(%{}) == []
    end

    test "componentId wins over child" do
      assert RefSpec.from_value(%{"componentId" => "a", "child" => "b"}) == [{"a", "componentId"}]
    end

    test "child object" do
      assert RefSpec.from_value(%{"child" => "b"}) == [{"b", "child"}]
    end

    test "deep objects use dotted paths and sorted keys" do
      value = %{"b" => %{"deep" => "two"}, "a" => "one"}
      assert RefSpec.from_value(value) == [{"one", "a"}, {"two", "b.deep"}]
    end

    test "subscripts attach without a dot" do
      assert RefSpec.from_value(%{"items" => ["a", "b"]}) ==
               [{"a", "items[0]"}, {"b", "items[1]"}]

      assert RefSpec.from_value([["a"]]) == [{"a", "[0][0]"}]
    end
  end
end

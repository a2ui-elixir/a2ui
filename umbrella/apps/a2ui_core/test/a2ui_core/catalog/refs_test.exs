defmodule A2UICore.Catalog.RefsTest do
  @moduledoc false
  use ExUnit.Case, async: true

  alias A2UICore.Catalog.Refs

  @peer %{
    catalog_id: "acme/widgets",
    schema_id: "https://acme.test/catalogs/widgets_v1.json",
    document: %{
      "components" => %{
        "Badge" => %{
          "type" => "object",
          "title" => "Badge",
          "properties" => %{
            "id" => %{"$ref" => "common_types.json#/$defs/ComponentId"},
            "component" => %{"const" => "Badge"},
            "label" => %{"$ref" => "#/$defs/Label"}
          },
          "required" => ["id", "component", "label"],
          "unevaluatedProperties" => false
        }
      },
      "$defs" => %{"Label" => %{"type" => "string", "maxLength" => 20}}
    }
  }

  describe "names_document?/2 and localize/2" do
    test "a document is named by its file name or a path ending in it" do
      assert Refs.names_document?("common_types.json", "common_types.json")
      assert Refs.names_document?("https://a2ui.org/v1_0/common_types.json", "common_types.json")
      refute Refs.names_document?("my_common_types.json", "common_types.json")
    end

    test "references into the common types and the catalog become local" do
      assert Refs.localize("common_types.json#/$defs/Child") == "#/$defs/Child"
      assert Refs.localize("catalog.json#/$defs/Own") == "#/$defs/Own"
      assert Refs.localize("https://x.test/catalog.json#/$defs/Own") == "#/$defs/Own"
      assert Refs.localize("#/$defs/Local") == "#/$defs/Local"
      assert Refs.localize("other.json#/$defs/Thing") == "other.json#/$defs/Thing"
      assert Refs.localize("common_types.json#/properties/x") == "common_types.json#/properties/x"
    end

    test "a catalog.json path that names a peer by id stays external" do
      peer = %{@peer | schema_id: "https://acme.test/catalog.json"}
      ref = "https://acme.test/catalog.json#/$defs/Label"

      assert Refs.localize(ref, [peer]) == ref
      assert Refs.normalize(%{"a" => [%{"$ref" => ref}]}, [peer]) == %{"a" => [%{"$ref" => ref}]}
    end
  end

  describe "find_peer/2" do
    test "matches ids exactly or by path suffix, then file names" do
      assert Refs.find_peer("acme/widgets", [@peer]) == @peer
      assert Refs.find_peer("catalogs/widgets_v1.json", [@peer]) == @peer
      assert Refs.find_peer("https://acme.test/catalogs/widgets_v1.json", [@peer]) == @peer
      assert Refs.find_peer("../elsewhere/widgets_v1.json", [@peer]) == @peer
      assert Refs.find_peer("gadgets.json", [@peer]) == nil
    end

    test "the common types, catalog.json and an empty document name no peer" do
      assert Refs.find_peer("common_types.json", [@peer]) == nil
      assert Refs.find_peer("catalog.json", [@peer]) == nil
      assert Refs.find_peer("", [@peer]) == nil
      assert Refs.find_peer("acme/widgets", []) == nil

      peer = %{@peer | schema_id: "https://acme.test/catalog.json", catalog_id: nil}
      assert Refs.find_peer("../other/catalog.json", [peer]) == nil
      assert Refs.find_peer("https://acme.test/catalog.json", [peer]) == peer
    end
  end

  describe "reference analysis" do
    test "cross_document?/1 finds references naming another document" do
      assert Refs.cross_document?(%{"a" => [%{"$ref" => "widgets.json#/components/Badge"}]})
      assert Refs.cross_document?(%{"$ref" => "#/x", "b" => %{"$ref" => "w.json#/y"}})
      refute Refs.cross_document?(%{"$ref" => "common_types.json#/$defs/Child"})
      refute Refs.cross_document?(%{"$ref" => "catalog.json#/$defs/Own"})
      refute Refs.cross_document?(%{"$ref" => "#/$defs/Local"})
      refute Refs.cross_document?(%{"$ref" => "no-fragment.json"})
      refute Refs.cross_document?("text")
    end

    test "def_refs/1, own_def_refs/1 and own_def_name/1" do
      node = %{
        "a" => %{"$ref" => "#/$defs/One/properties/x"},
        "b" => [%{"$ref" => "catalog.json#/$defs/Two"}, %{"$ref" => "other.json#/$defs/Three"}]
      }

      assert Refs.def_refs(node) == MapSet.new(["One"])
      assert Refs.own_def_refs(node) == MapSet.new(["One", "Two"])
      assert Refs.own_def_name("#/components/Text") == nil
      assert Refs.own_def_name("no-fragment") == nil
      assert Refs.own_def_name(nil) == nil
    end

    test "reachable_defs/2 follows definitions transitively" do
      defs = %{
        "A" => %{"$ref" => "#/$defs/B"},
        "B" => %{"items" => %{"$ref" => "catalog.json#/$defs/C"}},
        "C" => %{"type" => "string"},
        "D" => %{"type" => "number"}
      }

      assert Refs.reachable_defs([%{"$ref" => "#/$defs/A"}, %{"$ref" => "#/$defs/Gone"}], defs) ==
               MapSet.new(["A", "B", "C"])
    end

    test "externalize/3 points common types at the common types document" do
      common = MapSet.new(["Child"])
      node = %{"a" => [%{"$ref" => "#/$defs/Child"}, %{"$ref" => "#/$defs/Own"}], "b" => 1}

      assert Refs.externalize(node, common) == %{
               "a" => [%{"$ref" => "common_types.json#/$defs/Child"}, %{"$ref" => "#/$defs/Own"}],
               "b" => 1
             }

      assert Refs.externalize(%{"$ref" => "#/$defs/Child"}, common, "ct.json") ==
               %{"$ref" => "ct.json#/$defs/Child"}
    end

    test "query/2 follows a JSON pointer with escapes" do
      document = %{"a" => %{"b/c" => %{"d~e" => 1}}}

      assert Refs.query(document, "#/a/b~1c/d~0e") == 1
      assert Refs.query(document, "#/a/missing") == nil
      assert Refs.query(document, "a/b") == nil
    end
  end

  describe "inline/4" do
    test "local references are written inline with their sibling keys merged" do
      root = %{
        "$defs" => %{
          "Base" => %{"type" => "object", "properties" => %{"a" => %{}}, "required" => ["a"]},
          "Loop" => %{"items" => %{"$ref" => "#/$defs/Loop"}}
        }
      }

      node = %{
        "x" => %{
          "$ref" => "#/$defs/Base",
          "properties" => %{"b" => %{}},
          "required" => ["a", "b"],
          "description" => "d"
        },
        "y" => %{"$ref" => "#/$defs/Loop"},
        "z" => %{"$ref" => "#/$defs/Missing", "description" => "kept"}
      }

      inlined = Refs.inline(node, root, [], MapSet.new())

      assert inlined["x"] == %{
               "type" => "object",
               "properties" => %{"a" => %{}, "b" => %{}},
               "required" => ["a", "b"],
               "description" => "d"
             }

      assert inlined["y"] == %{"items" => %{"$ref" => "#/$defs/Loop"}}
      assert inlined["z"] == %{"$ref" => "#/$defs/Missing", "description" => "kept"}
    end

    test "preserved common types stay as references" do
      preserved = MapSet.new(["Child"])

      assert Refs.inline(%{"$ref" => "common_types.json#/$defs/Child"}, %{}, [], preserved) ==
               %{"$ref" => "common_types.json#/$defs/Child"}

      assert Refs.inline(%{"$ref" => "common_types.json#/properties/x"}, %{}, [], preserved) ==
               %{"$ref" => "common_types.json#/properties/x"}
    end

    test "a peer component is inlined without its envelope" do
      node = %{"$ref" => "widgets_v1.json#/components/Badge"}
      preserved = MapSet.new(["ComponentId"])

      assert Refs.inline(node, %{}, [@peer], preserved) == %{
               "type" => "object",
               "properties" => %{"label" => %{"type" => "string", "maxLength" => 20}},
               "required" => ["label"]
             }

      label = %{"$ref" => "acme/widgets#/components/Badge/properties/label"}

      assert Refs.inline(label, %{}, [@peer], preserved) ==
               %{"type" => "string", "maxLength" => 20}
    end

    test "references into catalog.json resolve in the root; unknown documents stay" do
      root = %{"$defs" => %{"Own" => %{"type" => "boolean"}}}

      assert Refs.inline(%{"$ref" => "catalog.json#/$defs/Own"}, root, [], MapSet.new()) ==
               %{"type" => "boolean"}

      assert Refs.inline(%{"$ref" => "nowhere.json#/$defs/X"}, root, [], MapSet.new()) ==
               %{"$ref" => "nowhere.json#/$defs/X"}

      assert Refs.inline(%{"$ref" => "nowhere.json"}, root, [], MapSet.new()) ==
               %{"$ref" => "nowhere.json"}
    end
  end

  test "strip_envelope/1 drops the envelope through allOf, specific members first" do
    schema = %{
      "title" => "Card",
      "additionalProperties" => false,
      "allOf" => [
        %{"$ref" => "common_types.json#/$defs/ComponentCommon"},
        %{
          "properties" => %{"component" => %{"const" => "Card"}, "child" => %{}},
          "required" => ["component", "child"]
        },
        "odd"
      ]
    }

    assert Refs.strip_envelope(schema) == %{
             "allOf" => [
               %{"properties" => %{"child" => %{}}, "required" => ["child"]},
               %{"$ref" => "common_types.json#/$defs/ComponentCommon"},
               "odd"
             ]
           }

    assert Refs.strip_envelope(%{"properties" => 1, "required" => 2, "allOf" => 3}) ==
             %{"properties" => 1, "required" => 2, "allOf" => 3}
  end
end

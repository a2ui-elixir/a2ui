defmodule A2UIAgent.BuilderTest do
  use ExUnit.Case, async: true

  import A2UIAgent.Builder
  import A2UIAgent.Builder.Basic

  alias A2UIAgent.Builder.{Binding, ChildList, Component, FunctionCall, Ref}
  alias A2UIAgent.Macro
  alias A2UICore.Catalog.Basic

  doctest A2UIAgent.Builder

  defp ids(components), do: Enum.map(components, & &1["id"])

  describe "nodes and values" do
    test "component/2 takes the id out and writes atom keys in lower camel case" do
      node = component("TextField", id: "zip", label: "ZIP", validation_regexp: "^[0-9]+$")

      assert %Component{component: "TextField", id: "zip"} = node
      assert node.props == [{"label", "ZIP"}, {"validationRegexp", "^[0-9]+$"}]
    end

    test "component/2 joins the parts of a snake case key" do
      assert component("X", foo__bar: 1).props == [{"fooBar", 1}]
    end

    test "component/2 takes maps, keeps string keys and leading underscores as given" do
      node = component("Custom", %{"max_items" => 3, _private: true})
      assert Enum.sort(node.props) == [{"_private", true}, {"max_items", 3}]
    end

    test "component/2 refuses bad properties" do
      assert_raise ArgumentError, ~r/first argument/, fn -> component("Text", component: "X") end
      assert_raise ArgumentError, ~r/must be a string/, fn -> component("Text", id: 1) end
      assert_raise ArgumentError, ~r/keyword list or a map/, fn -> component("Text", [1]) end
      assert_raise ArgumentError, ~r/keyword list or a map/, fn -> component("Text", "x") end
    end

    test "the value constructors" do
      assert ref("x") == %Ref{id: "x"}
      assert bind("/a") == %Binding{path: "/a"}
      assert child_list("/items", ref("t")) == %ChildList{path: "/items", template: %Ref{id: "t"}}

      assert call("formatNumber", value: 1, max_digits: 2) == %FunctionCall{
               call: "formatNumber",
               args: %{"value" => 1, "maxDigits" => 2}
             }

      assert call("now", [], return_type: "string").return_type == "string"
      assert event("go") == %{"event" => %{"name" => "go"}}

      assert event("go", %{"user_id" => 1}) == %{
               "event" => %{"name" => "go", "context" => %{"user_id" => 1}}
             }

      assert action(call("openUrl", url: "u")) == %{"functionCall" => call("openUrl", url: "u")}
      assert check(true, "m") == %{"condition" => true, "message" => "m"}
      assert accessibility(%{"label" => "L"}) == %{"label" => "L"}
    end
  end

  describe "ids" do
    test "a root without an id is named under the prefix root" do
      assert ids(flatten(card(child: text(text: "a")))) == ["root__text_1", "root__card_1"]
    end

    test "a root id names the root and prefixes the others" do
      tree = card(id: "own", child: text(id: "t", text: "a"))
      assert ids(flatten(tree, root_id: "panel")) == ["panel__t", "panel"]
    end

    test "made ids skip ids the author gave, bare or under the prefix" do
      tree =
        column(
          id: "c",
          children: [text(text: "a"), text(id: "text_2", text: "b"), text(text: "c")]
        )

      assert ids(flatten(tree)) == ["c__text_1", "c__text_2", "c__text_3", "c"]

      tree = column(id: "c", children: [text(text: "a"), text(id: "c__text_1", text: "b")])
      assert ids(flatten(tree)) == ["c__text_2", "c__c__text_1", "c"]
    end

    test "a list of trees is flattened tree by tree" do
      trees = [text(id: "a", text: "1"), text(text: "2")]
      assert ids(flatten(trees)) == ["a", "root__text_1"]
      assert ids(flatten(trees, root_id: "row")) == ["row_0", "row_1"]
    end

    test "a reference is written as its id and never emitted" do
      assert flatten(ref("elsewhere")) == []

      assert [%{"children" => ["elsewhere"]}] =
               flatten(column(id: "c", children: [ref("elsewhere")]))
    end

    test "flatten/2 refuses what is not a tree" do
      assert_raise ArgumentError, ~r/component tree/, fn -> flatten("text") end
    end
  end

  describe "values" do
    test "bindings and function calls use the version's keys" do
      tree = text(id: "t", text: call("formatString", value: bind("/name")))

      assert [
               %{
                 "text" => %{
                   "call" => "formatString",
                   "args" => %{"value" => %{"path" => "/name"}}
                 }
               }
             ] =
               flatten(tree, version: "v0.9")

      assert [
               %{
                 "text" => %{
                   "@call" => "formatString",
                   "args" => %{"value" => %{"@path" => "/name"}}
                 }
               }
             ] =
               flatten(tree)
    end

    test "a function call writes its return type" do
      assert [%{"text" => %{"returnType" => "string"}}] =
               flatten(text(id: "t", text: call("now", [], return_type: "string")))
    end

    test "a child list emits its template" do
      tree =
        column(id: "feed", children: child_list("/posts", text(id: "post", text: bind("title"))))

      assert [
               %{"id" => "feed__post", "text" => %{"@path" => "title"}},
               %{
                 "id" => "feed",
                 "children" => %{"path" => "/posts", "componentId" => "feed__post"}
               }
             ] = flatten(tree)
    end

    test "children inside maps are emitted, atoms become strings and nil properties are left out" do
      tree =
        tabs(
          id: "tabs",
          tabs: [%{"title" => "One", "child" => text(text: "1")}],
          weight: nil,
          mode: :compact
        )

      assert [
               %{"id" => "tabs__text_1"},
               %{"id" => "tabs", "tabs" => [%{"title" => "One", "child" => "tabs__text_1"}]} =
                 tabs
             ] = flatten(tree)

      assert tabs["mode"] == "compact"

      assert [%{"text" => %{"a" => 1}}] = flatten(text(id: "t", text: %{a: 1}))
      refute Map.has_key?(tabs, "weight")
    end

    test "a value JSON cannot hold raises" do
      assert_raise ArgumentError, ~r/as JSON/, fn -> flatten(text(id: "t", text: {:a, 1})) end

      assert_raise ArgumentError, ~r/object key/, fn ->
        flatten(text(id: "t", text: %{{:a} => 1}))
      end
    end
  end

  describe "catalogs" do
    setup do
      %{v09: Basic.catalog("v0.9.1"), v10: Basic.catalog("v1.0")}
    end

    test "components get the catalog's defaults, unless the node sets the property", %{v09: v09} do
      assert [%{"variant" => "body"}, %{"justify" => "start", "align" => "stretch"}] =
               flatten(column(id: "c", children: [text(text: "a")]), catalog: v09)

      assert [%{} = text] = flatten(text(id: "t", text: "a", variant: nil), catalog: v09)
      refute Map.has_key?(text, "variant")
    end

    test "children are emitted in the catalog's order of their properties", %{v10: v10} do
      tree = modal(id: "m", content: text(text: "content"), trigger: text(text: "trigger"))

      assert [%{"text" => "trigger"}, %{"text" => "content"}, _modal] =
               flatten(tree, catalog: v10)

      assert [%{"text" => "content"}, %{"text" => "trigger"}, _modal] = flatten(tree)
    end

    test "a component the catalog rejects raises", %{v10: v10} do
      assert_raise A2UICore.Error, fn ->
        flatten(text(id: "t", text: "a", variant: "h1"), catalog: v10)
      end

      assert_raise A2UICore.Error, fn -> flatten(component("Nope", id: "n"), catalog: v10) end

      assert [%{"variant" => "h1"}] =
               flatten(text(id: "t", text: "a", variant: "h1"), catalog: v10, validate: false)
    end

    test "a catalog read from maps, and references that loop" do
      {:ok, catalog} =
        A2UICore.Catalog.from_json(%{
          "catalogId" => "https://example.com/loop.json",
          "protocolVersion" => "v1.0",
          "components" => %{
            "Loop" => %{
              "allOf" => [%{"$ref" => "#/$defs/Loop"}],
              "properties" => %{"size" => %{"type" => "number", "default" => 1}}
            }
          },
          "$defs" => %{"Loop" => %{"allOf" => [%{"$ref" => "#/$defs/Loop"}]}}
        })

      assert [%{"size" => 1}] =
               flatten(component("Loop", id: "l"), catalog: catalog, validate: false)
    end

    test "the catalog's version picks the keys", %{v09: v09} do
      assert [%{"text" => %{"path" => "/a"}}] =
               flatten(text(id: "t", text: bind("/a")), catalog: v09)
    end
  end

  describe "macro calls" do
    setup do
      label =
        Macro.new("Label", [text: :string], fn %{text: value} ->
          text(text: String.upcase(value))
        end)

      loop = Macro.new("Loop", [], fn _ -> card(child: Macro.call("Loop")) end)
      %{label: label, loop: loop}
    end

    test "a call expands in the tree's scope", %{label: label} do
      tree =
        column(
          id: "c",
          children: [Macro.call(label, text: "a"), Macro.call("Label", %{"text" => "b"})]
        )

      assert [
               %{"id" => "c__text_1", "text" => "A"},
               %{"id" => "c__text_2", "text" => "B"},
               _column
             ] =
               flatten(tree, macros: [label])

      assert [_a, _b, _column] = flatten(tree, macros: %{"Label" => label})
    end

    test "the recursion error names the macro called too deep" do
      deepest = Macro.new("Level0", [], fn _ -> text(text: "end") end)

      outer =
        Enum.reduce(1..20, deepest, fn index, inner ->
          Macro.new("Level#{index}", [], fn _ -> Macro.call(inner) end)
        end)

      error = assert_raise A2UICore.Error, fn -> flatten(Macro.call(outer)) end
      assert error.message =~ ~s(calling "Level3")
    end

    test "a call of an unknown macro raises" do
      assert_raise ArgumentError, ~r/no macro named "Label"/, fn ->
        flatten(column(id: "c", children: [Macro.call("Label", text: "a")]))
      end
    end

    test "calls nested too deep raise a recursion error", %{loop: loop} do
      error = assert_raise A2UICore.Error, fn -> flatten(Macro.call(loop), macros: [loop]) end
      assert error.category == :recursion
    end

    test "a macro component the flattening knows is not checked against the catalog", %{
      label: label
    } do
      tree = column(id: "c", children: [component("Label", text: "a")])

      assert [%{"component" => "Label"}, _column] =
               flatten(tree, catalog: Basic.catalog("v1.0"), macros: [label])
    end
  end

  describe "messages/2" do
    test "creates the surface, sets components and writes the data model" do
      tree = text(id: "root", text: bind("/name"))

      assert [
               %{
                 "version" => "v0.9",
                 "createSurface" => %{"surfaceId" => "s", "catalogId" => "cat"}
               },
               %{
                 "version" => "v0.9",
                 "updateComponents" => %{"components" => [%{"text" => %{"path" => "/name"}}]}
               },
               %{
                 "version" => "v0.9",
                 "updateDataModel" => %{"path" => "/name", "value" => "Ada"}
               },
               %{"updateDataModel" => %{"path" => "/n", "value" => 1}}
             ] =
               messages(tree,
                 surface_id: "s",
                 catalog_id: "cat",
                 data_model: [{"/name", "Ada"}, {"/n", 1}],
                 version: "v0.9"
               )
    end

    test "the catalog's version, else v1.0" do
      assert [%{"version" => "v0.9.1"}] =
               messages(text(id: "root", text: "a"),
                 surface_id: "s",
                 catalog: Basic.catalog("v0.9.1")
               )

      assert [%{"version" => "v1.0"}, %{"updateDataModel" => %{"path" => "/a"}}] =
               messages(text(id: "root", text: "a"), surface_id: "s", data_model: %{"/a" => 1})
    end
  end
end

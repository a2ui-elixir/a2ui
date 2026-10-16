defmodule A2UIAgent.MacroExpanderTest do
  use ExUnit.Case, async: true

  import A2UIAgent.Builder.Basic
  import ExUnit.CaptureLog

  alias A2UIAgent.{Builder, Macro, MacroExpander}
  alias A2UICore.Catalog
  alias A2UICore.Catalog.Basic

  setup do
    badge =
      Macro.new(
        "Badge",
        [label: :string, tone: [type: {:enum, ["info", "alert"]}, default: "info"]],
        fn %{label: label, tone: tone} ->
          row(
            children: [
              icon(name: "info"),
              text(text: label, variant: "caption"),
              text(text: tone)
            ]
          )
        end,
        description: "A badge."
      )

    panel =
      Macro.new("Panel", [title: :string, body: :component], fn %{title: title, body: body} ->
        card(child: column(children: [Macro.call("Badge", label: title), body]))
      end)

    %{basic: Basic.catalog("v1.0"), badge: badge, panel: panel}
  end

  defp update(components, version \\ "v1.0"),
    do: %{
      "version" => version,
      "updateComponents" => %{"surfaceId" => "s", "components" => components}
    }

  test "macro names must be unique", %{basic: basic, badge: badge} do
    assert_raise ArgumentError, ~r/unique/, fn -> MacroExpander.new(basic, [badge, badge]) end
  end

  describe "inference_catalog/1" do
    test "adds the macros as components and to the union", %{
      basic: basic,
      badge: badge,
      panel: panel
    } do
      assert {:ok, catalog} =
               MacroExpander.inference_catalog(MacroExpander.new(basic, [badge, panel]))

      assert catalog.catalog_id == basic.catalog_id
      assert catalog.protocol_version == basic.protocol_version
      assert catalog.component_order == basic.component_order ++ ["Badge", "Panel"]

      schema = Catalog.to_json(catalog)["components"]["Badge"]
      assert schema["description"] == "A badge."
      assert schema["required"] == ["label"]

      assert schema["properties"]["tone"] == %{
               "type" => "string",
               "enum" => ["info", "alert"],
               "description" => "Tone"
             }
    end

    test "keeps only the passthrough components", %{basic: basic, badge: badge} do
      expander = MacroExpander.new(basic, [badge], passthrough_components: ["Text", "Row"])
      assert {:ok, catalog} = MacroExpander.inference_catalog(expander)
      assert catalog.component_order == ["Text", "Row", "Badge"]

      assert {:ok, only} =
               MacroExpander.inference_catalog(
                 MacroExpander.new(basic, [badge], passthrough_components: [])
               )

      assert only.component_order == ["Badge"]
    end

    test "passthrough over a catalog read from maps", %{badge: badge} do
      {:ok, plain} =
        Catalog.from_json(%{
          "catalogId" => "https://example.com/plain.json",
          "protocolVersion" => "v1.0",
          "components" => %{
            "Label" => %{"type" => "object", "properties" => %{"text" => %{"type" => "string"}}},
            "Extra" => %{"type" => "object"}
          }
        })

      expander = MacroExpander.new(plain, [badge], passthrough_components: ["Label"])
      assert {:ok, catalog} = MacroExpander.inference_catalog(expander)
      assert catalog.component_order == ["Label", "Badge"]
    end

    test "a macro named like a base component is a catalog error", %{basic: basic} do
      text_macro = Macro.new("Text", [], fn _ -> text(text: "x") end)

      assert {:error, %A2UICore.Error{category: :catalog, message: message}} =
               MacroExpander.inference_catalog(MacroExpander.new(basic, [text_macro]))

      assert message =~ "collides"
    end

    test "a base catalog with an authored union gets the macros appended to it", %{badge: badge} do
      v09 = Basic.catalog("v0.9.1")
      assert {:ok, catalog} = MacroExpander.inference_catalog(MacroExpander.new(v09, [badge]))

      refs = get_in(Catalog.validation_schema(catalog), ["$defs", "anyComponent", "oneOf"])
      assert List.last(refs) == %{"$ref" => "#/components/Badge"}
    end

    test "a base catalog without components", %{badge: badge} do
      {:ok, empty} = Catalog.new("https://example.com/empty.json", "v1.0")
      assert {:ok, catalog} = MacroExpander.inference_catalog(MacroExpander.new(empty, [badge]))
      assert catalog.component_order == ["Badge"]
    end
  end

  test "macro_catalog/1 holds the macros alone", %{basic: basic, badge: badge, panel: panel} do
    catalog = MacroExpander.macro_catalog(MacroExpander.new(basic, [badge, panel]))

    assert catalog.catalog_id == "https://a2ui.org/catalogs/macros"
    assert catalog.protocol_version == "v1.0"
    assert catalog.component_order == ["Badge", "Panel"]
  end

  describe "to_transport/2" do
    test "expands macro components, rooted at their ids", %{basic: basic, badge: badge} do
      expander = MacroExpander.new(basic, [badge])
      plain = %{"id" => "title", "component" => "Text", "text" => "Hi"}
      macro = %{"id" => "b", "component" => "Badge", "label" => "New"}

      assert {:ok, [message]} = MacroExpander.to_transport(expander, [update([plain, macro])])

      assert [
               ^plain,
               %{"id" => "b__icon_1", "component" => "Icon"},
               %{"id" => "b__text_1", "text" => "New", "variant" => "caption"},
               %{"id" => "b__text_2", "text" => "info", "variant" => "body"},
               %{
                 "id" => "b",
                 "component" => "Row",
                 "children" => ["b__icon_1", "b__text_1", "b__text_2"]
               }
             ] = message["updateComponents"]["components"]
    end

    test "reads arguments under parameters, and expands the inline components of createSurface",
         %{basic: basic, badge: badge} do
      expander = MacroExpander.new(basic, [badge])

      create = %{
        "version" => "v1.0",
        "createSurface" => %{
          "surfaceId" => "s",
          "catalogId" => basic.catalog_id,
          "components" => [
            %{
              "id" => "root",
              "component" => "Badge",
              "parameters" => %{"label" => "A", "tone" => "alert"}
            }
          ]
        }
      }

      assert {:ok, [message]} = MacroExpander.to_transport(expander, [create])
      components = message["createSurface"]["components"]
      assert %{"id" => "root", "component" => "Row"} = List.last(components)
      assert Enum.any?(components, &(&1["text"] == "alert"))
    end

    test "nested macro calls expand in the outer macro's scope", %{
      basic: basic,
      badge: badge,
      panel: panel
    } do
      expander = MacroExpander.new(basic, [badge, panel])
      macro = %{"id" => "p", "component" => "Panel", "title" => "T", "body" => "outside"}

      assert {:ok, [message]} = MacroExpander.to_transport(expander, [update([macro])])

      assert ["p__icon_1", "p__text_1", "p__text_2", "p__row_1", "p__column_1", "p"] =
               Enum.map(message["updateComponents"]["components"], & &1["id"])
    end

    test "components an expansion makes may be macros themselves", %{basic: basic, badge: badge} do
      wrapper =
        Macro.new("Wrapper", [], fn _ ->
          card(child: Builder.component("Badge", label: "inner"))
        end)

      expander = MacroExpander.new(basic, [badge, wrapper])

      assert {:ok, [message]} =
               MacroExpander.to_transport(expander, [
                 update([%{"id" => "w", "component" => "Wrapper"}])
               ])

      ids = Enum.map(message["updateComponents"]["components"], & &1["id"])
      assert "w__badge_1" in ids
      assert "w__badge_1__text_1" in ids
      assert List.last(ids) == "w"
    end

    test "bindings are written for each message's version", %{badge: badge} do
      expander = MacroExpander.new(Basic.catalog("v0.9.1"), [badge])
      macro = %{"id" => "b", "component" => "Badge", "label" => %{"path" => "/label"}}

      assert {:ok, [message]} = MacroExpander.to_transport(expander, [update([macro], "v0.9")])

      assert Enum.any?(
               message["updateComponents"]["components"],
               &(&1["text"] == %{"path" => "/label"})
             )
    end

    test "a macro that fails keeps its component and logs why", %{basic: basic, badge: badge} do
      expander = MacroExpander.new(basic, [badge])
      macro = %{"id" => "b", "component" => "Badge"}

      log =
        capture_log(fn ->
          assert {:ok, [message]} = MacroExpander.to_transport(expander, [update([macro])])
          assert message["updateComponents"]["components"] == [macro]
        end)

      assert log =~ "Failed to expand macro \"Badge\""
    end

    test "an expansion the catalog rejects keeps its component", %{basic: basic} do
      bad = Macro.new("Bad", [], fn _ -> text(text: "x", variant: "h1") end)
      macro = %{"id" => "b", "component" => "Bad"}

      capture_log(fn ->
        assert {:ok, [message]} =
                 MacroExpander.to_transport(MacroExpander.new(basic, [bad]), [update([macro])])

        assert message["updateComponents"]["components"] == [macro]
      end)
    end

    test "expansion too deep fails the call", %{basic: basic} do
      loop = Macro.new("Loop", [], fn _ -> card(child: Macro.call("Loop")) end)

      assert {:error, %A2UICore.Error{category: :recursion}} =
               MacroExpander.to_transport(MacroExpander.new(basic, [loop]), [
                 update([%{"id" => "l", "component" => "Loop"}])
               ])

      echo = Macro.new("Echo", [], fn _ -> Builder.component("Echo") end)

      assert {:error, %A2UICore.Error{category: :recursion}} =
               MacroExpander.to_transport(MacroExpander.new(basic, [echo]), [
                 update([%{"id" => "e", "component" => "Echo"}])
               ])
    end

    test "other messages, and expanders without macros, are left alone", %{
      basic: basic,
      badge: badge
    } do
      data = %{
        "version" => "v1.0",
        "updateDataModel" => %{"surfaceId" => "s", "path" => "/a", "value" => 1}
      }

      empty = update([])
      odd = update(["not a component", %{"id" => "x"}])

      assert {:ok, [^data, ^empty, ^odd]} =
               MacroExpander.to_transport(MacroExpander.new(basic, [badge]), [data, empty, odd])

      macro = update([%{"id" => "b", "component" => "Badge", "label" => "x"}])
      assert {:ok, [^macro]} = MacroExpander.to_transport(MacroExpander.new(basic, []), [macro])
    end
  end

  test "to_inference/2 returns messages as they are", %{basic: basic, badge: badge} do
    messages = [update([%{"id" => "b", "component" => "Badge", "label" => "x"}])]
    assert MacroExpander.to_inference(MacroExpander.new(basic, [badge]), messages) == messages
  end
end

defmodule A2UIPhoenix.ComponentsTest do
  @moduledoc false
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest, only: [render_component: 2]

  doctest A2UIPhoenix.Components
  doctest A2UIPhoenix.Components.Basic
  doctest A2UIPhoenix.Context

  alias A2UICore.Catalog.Basic, as: BasicCatalog
  alias A2UICore.Resolution.NodeResolver
  alias A2UIPhoenix.{Components, Context, Session}
  alias A2UIPhoenix.Components.Basic

  @v1 "https://a2ui.org/specification/v1_0/catalogs/basic/catalog.json"
  @v09 "https://a2ui.org/specification/v0_9/catalogs/basic/catalog.json"

  defp render_surface(components, options \\ []) do
    {version, catalog_id} = if options[:v09], do: {"v0.9", @v09}, else: {"v1.0", @v1}
    session = Session.new([BasicCatalog.catalog("v1.0"), BasicCatalog.catalog("v0.9.1")])

    {:ok, session, _effects} =
      Session.handle_message(session, [
        %{
          "version" => version,
          "createSurface" => %{"surfaceId" => "s", "catalogId" => catalog_id}
        },
        %{
          "version" => version,
          "updateDataModel" => %{"surfaceId" => "s", "value" => options[:data] || %{}}
        },
        %{
          "version" => version,
          "updateComponents" => %{"surfaceId" => "s", "components" => components}
        }
      ])

    resolver = Session.resolver(session, "s")

    ctx = %Context{
      surface_id: "s",
      surface: Session.surface(session, "s"),
      resolver: resolver,
      components: Map.merge(Basic.components(), options[:components] || %{}),
      ui: options[:ui] || %{}
    }

    render_component(&Components.component_node/1, ctx: ctx, ref: NodeResolver.root(resolver).ref)
  end

  describe "placeholders" do
    test "an unknown type, a cycle and a type without a renderer" do
      assert render_surface([%{"id" => "root", "component" => "Sparkle"}]) =~
               ~s(class="a2ui-placeholder a2ui-unknown_type")

      cyclic = render_surface([%{"id" => "root", "component" => "Card", "child" => "root"}])
      assert cyclic =~ ~s(class="a2ui-placeholder a2ui-cyclic")

      unrendered =
        render_surface([%{"id" => "root", "component" => "Divider"}],
          components: %{"Divider" => nil}
        )

      assert unrendered =~ ~s(class="a2ui-placeholder a2ui-unrendered")
      assert unrendered =~ ~s(data-a2ui-type="Divider")
    end

    test "a missing node renders nothing" do
      ctx = %Context{surface_id: "s"}
      assert render_component(&Components.component_node/1, ctx: ctx, ref: 1) == ""
    end
  end

  describe "basic components" do
    test "v0.9 headings and captions" do
      html =
        render_surface(
          [
            %{"id" => "root", "component" => "Column", "children" => ["h", "c"]},
            %{"id" => "h", "component" => "Text", "text" => "Title", "variant" => "h2"},
            %{"id" => "c", "component" => "Text", "text" => "small", "variant" => "caption"}
          ],
          v09: true
        )

      assert html =~ "<h2>Title</h2>"
      assert html =~ "<em>small</em>"
    end

    test "media" do
      html =
        render_surface([
          %{
            "id" => "root",
            "component" => "Column",
            "children" => ["img", "svg", "named", "vid", "aud", "line"]
          },
          %{
            "id" => "img",
            "component" => "Image",
            "url" => "/a.png",
            "fit" => "scaleDown",
            "weight" => 2
          },
          %{"id" => "svg", "component" => "Icon", "name" => %{"svgPath" => "M0 0L1 1"}},
          %{
            "id" => "named",
            "component" => "Icon",
            "name" => "starOff",
            "accessibility" => %{"label" => "Not starred"}
          },
          %{"id" => "vid", "component" => "Video", "url" => "/v.mp4", "posterUrl" => "/p.png"},
          %{
            "id" => "aud",
            "component" => "AudioPlayer",
            "url" => "/a.mp3",
            "description" => "Episode 1"
          },
          %{"id" => "line", "component" => "Divider", "axis" => "vertical"}
        ])

      assert html =~ ~s(style="flex: 2; object-fit: scale-down")
      assert html =~ ~s(<path d="M0 0L1 1">)
      assert html =~ ~r/<i class="material-icons a2ui-icon"[^>]*role="img"[^>]*>star_border<\/i>/
      assert html =~ ~s(aria-label="Not starred")
      assert html =~ ~s(poster="/p.png")
      assert html =~ "Episode 1"
      assert html =~ ~s(aria-orientation="vertical")
    end

    test "text field variants" do
      html =
        render_surface(
          [
            %{"id" => "root", "component" => "Column", "children" => ["long", "secret", "n"]},
            %{
              "id" => "long",
              "component" => "TextField",
              "label" => "Notes",
              "variant" => "longText",
              "value" => %{"@path" => "/notes"}
            },
            %{
              "id" => "secret",
              "component" => "TextField",
              "label" => "Password",
              "variant" => "obscured",
              "placeholder" => "••••"
            },
            %{
              "id" => "n",
              "component" => "TextField",
              "label" => "Age",
              "variant" => "number",
              "value" => 42
            }
          ],
          data: %{"notes" => "line one"}
        )

      assert html =~ ~r/<textarea[^>]*>line one<\/textarea>/
      assert html =~ ~s(type="password")
      assert html =~ ~s(placeholder="••••")
      assert html =~ ~s(type="number")
      assert html =~ ~s(value="42")
    end

    test "date bounds and a single choice given as a string" do
      html =
        render_surface([
          %{"id" => "root", "component" => "Column", "children" => ["when", "pick"]},
          %{
            "id" => "when",
            "component" => "DateTimeInput",
            "value" => "2026-05-05",
            "min" => "2026-01-01T00:00:00",
            "max" => "later",
            "label" => "When"
          },
          %{
            "id" => "pick",
            "component" => "ChoicePicker",
            "options" => [%{"label" => "A", "value" => "a"}, %{"label" => "B", "value" => "b"}],
            "value" => "a"
          }
        ])

      assert html =~ ~s(min="2026-01-01")
      refute html =~ "max="
      assert html =~ ~r/<input type="radio"[^>]*value="a"[^>]*checked/
    end

    test "an open tab beyond the last falls back to the first" do
      components = [
        %{
          "id" => "root",
          "component" => "Tabs",
          "tabs" => [%{"title" => "Only", "child" => "a"}]
        },
        %{"id" => "a", "component" => "Text", "text" => "only body"}
      ]

      assert render_surface(components, ui: %{1 => %{tab: 3}}) =~ "only body"
    end

    test "a list of children with a vertical direction" do
      html =
        render_surface([
          %{
            "id" => "root",
            "component" => "List",
            "children" => ["a"],
            "direction" => "horizontal",
            "align" => "center"
          },
          %{"id" => "a", "component" => "Text", "text" => "item"}
        ])

      assert html =~ ~s(class="a2ui-list horizontal")
      assert html =~ "align-items: center"
    end
  end

  describe "helpers" do
    test "text/1 spells structured values as JSON" do
      assert Components.text(true) == "true"
      assert Components.text(%{"a" => [1]}) == ~s({"a":[1]})
    end

    test "error_ids/3 is nil while the checks pass" do
      ctx = %Context{surface_id: "s"}

      node = %A2UICore.Resolution.Node{
        ref: 1,
        instance_id: "x",
        component_id: "x",
        state: :resolved,
        data_path: "/"
      }

      assert Components.error_ids(ctx, node, %{"isValid" => true}) == nil

      assert Components.error_ids(ctx, node, %{"isValid" => false, "validationErrors" => []}) ==
               nil

      assert Components.error_ids(ctx, node, %{
               "isValid" => false,
               "validationErrors" => ["a", "b"]
             }) ==
               "a2ui-s-1-error-0 a2ui-s-1-error-1"
    end

    test "icon_name/1 of a non-string is empty" do
      assert Basic.icon_name(nil) == ""
    end
  end
end

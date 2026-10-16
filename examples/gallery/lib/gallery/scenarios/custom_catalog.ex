defmodule Gallery.Scenarios.CustomCatalog do
  @moduledoc """
  Catalogs beyond the basic one. The renderer adds a catalog of its own
  (`priv/catalogs/widgets_catalog.json`: `Badge`, `Progress`, the
  container `Panel`, and the function `initials`, which the renderer
  runs) and the restaurant catalog (`Rating`). One surface keeps the
  basic catalog as its default and names the other catalogs per
  component with `catalogId`; the other makes the gallery's catalog its
  default. The Capabilities tab shows the catalogs as the renderer
  announces them, inline.
  """

  use Gallery.Scenario

  alias Gallery.Catalogs
  alias GalleryWeb.WidgetComponents

  @widgets "https://example.com/a2ui/catalogs/widgets/v1/catalog.json"
  @restaurant "https://example.com/a2ui/catalogs/restaurant/v1/catalog.json"
  @basic "https://a2ui.org/specification/v1_0/catalogs/basic/catalog.json"

  def id, do: "custom"
  def title, do: "Custom catalogs"

  def summary,
    do:
      "A catalog of the renderer's own next to the basic one: its components, a container, a function it implements, and catalogId per component."

  def features,
    do: [
      "custom components",
      "custom container",
      "custom function",
      "catalogId per component",
      "catalogId per call",
      "several catalogs",
      "inline catalogs in capabilities"
    ]

  def catalogs, do: [Catalogs.basic("v1.0"), Catalogs.restaurant(), Catalogs.widgets()]

  def components, do: WidgetComponents.components()

  @team [
    %{
      "name" => "Grace Hopper",
      "role" => "Compilers",
      "status" => "on track",
      "progress" => 0.7,
      "rating" => 5
    },
    %{
      "name" => "Alan Turing",
      "role" => "Machines",
      "status" => "reviewing",
      "progress" => 0.4,
      "rating" => 4
    },
    %{
      "name" => "Katherine Johnson",
      "role" => "Trajectories",
      "status" => "blocked",
      "progress" => 0.15,
      "rating" => 4.5
    }
  ]

  def messages do
    [
      create("team",
        data: %{"sprint" => %{"progress" => 0.42}, "team" => @team},
        components: team()
      ),
      create("week",
        catalog_id: @widgets,
        data: %{"done" => 12, "open" => 5},
        components: week()
      )
    ]
  end

  defp widget(map), do: Map.put(map, "catalogId", @widgets)

  defp team do
    [
      %{
        "id" => "root",
        "component" => "Column",
        "children" => ["title", "intro", "sprint", "members"]
      },
      text("title", "## Team board"),
      text(
        "intro",
        "Badge, Progress and Panel come from the gallery's catalog and Rating from the restaurant catalog: " <>
          "each names its catalog with catalogId. The initials come from the gallery's function initials.",
        %{"variant" => "caption"}
      ),
      widget(%{
        "id" => "sprint",
        "component" => "Progress",
        "value" => path("/sprint/progress"),
        "label" => "Sprint"
      }),
      %{
        "id" => "members",
        "component" => "List",
        "children" => %{"componentId" => "member", "path" => "/team"}
      },
      %{"id" => "member", "component" => "Card", "child" => "memberRow"},
      %{
        "id" => "memberRow",
        "component" => "Row",
        "align" => "center",
        "children" => ["initials", "who", "status", "rating", "progress"]
      },
      widget(%{
        "id" => "initials",
        "component" => "Badge",
        "tone" => "info",
        "text" => %{
          "@call" => "initials",
          "catalogId" => @widgets,
          "args" => %{"name" => path("name")}
        }
      }),
      %{"id" => "who", "component" => "Column", "weight" => 1, "children" => ["name", "role"]},
      text("name", call("formatString", %{"value" => "#### ${name}"})),
      text("role", path("role"), %{"variant" => "caption"}),
      widget(%{
        "id" => "status",
        "component" => "Badge",
        "tone" => "warning",
        "text" => path("status")
      }),
      %{
        "id" => "rating",
        "component" => "Rating",
        "catalogId" => @restaurant,
        "value" => path("rating"),
        "label" => "peer review"
      },
      widget(%{
        "id" => "progress",
        "component" => "Progress",
        "value" => path("progress"),
        "accessibility" => %{"label" => call("formatString", %{"value" => "Progress of ${name}"})}
      })
    ]
  end

  # The gallery's catalog is this surface's default: the basic Text names
  # its catalog.
  defp week do
    [
      %{
        "id" => "root",
        "component" => "Panel",
        "title" => "This week",
        "children" => ["done", "open", "badges"]
      },
      %{
        "id" => "done",
        "component" => "Text",
        "catalogId" => @basic,
        "text" => %{
          "@call" => "formatString",
          "catalogId" => @basic,
          "args" => %{"value" => "${/done} tasks done."}
        }
      },
      %{
        "id" => "open",
        "component" => "Text",
        "catalogId" => @basic,
        "text" => %{
          "@call" => "formatString",
          "catalogId" => @basic,
          "args" => %{"value" => "${/open} still open."}
        }
      },
      %{
        "id" => "badges",
        "component" => "Row",
        "catalogId" => @basic,
        "children" => ["ok", "late"]
      },
      %{"id" => "ok", "component" => "Badge", "tone" => "success", "text" => "Release ready"},
      %{"id" => "late", "component" => "Badge", "tone" => "danger", "text" => "Docs late"}
    ]
  end

  def controls, do: [{"advance", "Move the sprint along"}, {"rename", "Rename a member"}]

  def control("advance") do
    [
      {100,
       [
         data("team", "/sprint/progress", 0.8),
         data("team", "/team/1/progress", 1.0),
         data("team", "/team/1/status", "done"),
         data("week", "/done", 15),
         data("week", "/open", 2)
       ]}
    ]
  end

  # initials runs again with the new name.
  def control("rename"), do: [{100, data("team", "/team/2/name", "Dorothy Vaughan")}]
  def control(_id), do: []
end

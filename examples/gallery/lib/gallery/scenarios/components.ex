defmodule Gallery.Scenarios.Components do
  @moduledoc """
  Every component of the basic catalog (protocol v1.0) on one surface,
  in tabs: text and media, layout, inputs bound two ways to the data
  model, and buttons and a modal. The agent answers the buttons'
  actions by updating a live region.
  """

  use Gallery.Scenario

  def id, do: "components"
  def title, do: "Component gallery"

  def summary,
    do: "All 18 components of the basic catalog, their variants, and accessibility attributes."

  def features,
    do: [
      "Text + Markdown",
      "Image",
      "Icon",
      "Video",
      "AudioPlayer",
      "Row / Column / List",
      "Card",
      "Tabs",
      "Modal",
      "Divider",
      "Button variants",
      "TextField",
      "CheckBox",
      "ChoicePicker",
      "Slider",
      "DateTimeInput",
      "two-way binding",
      "accessibility"
    ]

  def messages do
    [
      create("gallery",
        data: %{
          "lastAction" => "Nothing pressed yet.",
          "inputs" => %{
            "name" => "Ada",
            "bio" => "Mathematician.\nWrote the first program.",
            "age" => 36,
            "secret" => "",
            "subscribed" => true,
            "toppings" => ["basil"],
            "size" => ["medium"],
            "country" => ["fr"],
            "volume" => 40,
            "day" => "2026-10-17",
            "time" => "19:30",
            "when" => "2026-10-17T19:30"
          }
        },
        components:
          [
            %{"id" => "root", "component" => "Column", "children" => ["intro", "tabs", "status"]},
            text(
              "intro",
              "## The basic catalog\nEvery component of the catalog, as the renderer draws it. **Markdown** works in `Text`."
            ),
            %{
              "id" => "tabs",
              "component" => "Tabs",
              "tabs" => [
                %{"title" => "Text and media", "child" => "mediaTab"},
                %{"title" => "Layout", "child" => "layoutTab"},
                %{"title" => "Inputs", "child" => "inputsTab"},
                %{"title" => "Buttons and dialogs", "child" => "buttonsTab"}
              ]
            },
            text("status", path("/lastAction"), %{
              "variant" => "caption",
              "accessibility" => %{"label" => "Last action", "live" => "polite"}
            })
          ] ++ media() ++ layout() ++ inputs() ++ buttons()
      )
    ]
  end

  # A small label over a group: a level-5 heading.
  defp label(id, text), do: text(id, "##### " <> text)

  defp media do
    List.flatten([
      %{
        "id" => "mediaTab",
        "component" => "Column",
        "children" => [
          "typeLabel",
          "textHead",
          "body",
          "caption",
          "iconLabel",
          "icons",
          "imageLabel",
          "images",
          "videoLabel",
          "video",
          "audioLabel",
          "audio"
        ]
      },
      label("typeLabel", "Typography"),
      text("textHead", "### Notes from the engine room"),
      text(
        "body",
        "Body text with *emphasis*, **strong** words, `code` and a list:\n- one\n- two"
      ),
      text("caption", "A caption, for the small print.", %{"variant" => "caption"}),
      label("iconLabel", "Icons"),
      %{
        "id" => "icons",
        "component" => "Row",
        "children" => ["i1", "i2", "i3", "i4", "i5", "i6", "i7"],
        "align" => "center"
      },
      %{"id" => "i1", "component" => "Icon", "name" => "home"},
      %{"id" => "i2", "component" => "Icon", "name" => "favorite"},
      %{"id" => "i3", "component" => "Icon", "name" => "shoppingCart"},
      %{"id" => "i4", "component" => "Icon", "name" => "calendarToday"},
      %{"id" => "i5", "component" => "Icon", "name" => "play"},
      %{
        "id" => "i6",
        "component" => "Icon",
        "name" => "settings",
        "accessibility" => %{"label" => "Settings"}
      },
      %{
        "id" => "i7",
        "component" => "Icon",
        "name" => %{
          "svgPath" =>
            "M12 2 L15 9 L22 9 L16.5 13.5 L18.5 21 L12 16.5 L5.5 21 L7.5 13.5 L2 9 L9 9 Z"
        }
      },
      label("imageLabel", "Images"),
      %{
        "id" => "images",
        "component" => "Row",
        "align" => "end",
        "children" => ["avatarItem", "smallItem", "mediumItem"]
      },
      specimen("avatarItem", "avatar", "avatar"),
      %{
        "id" => "avatar",
        "component" => "Image",
        "url" => "/media/avatar.svg",
        "variant" => "avatar",
        "description" => "A person"
      },
      specimen("smallItem", "small", "smallFeature"),
      %{
        "id" => "small",
        "component" => "Image",
        "url" => "/media/landscape.svg",
        "variant" => "smallFeature",
        "fit" => "cover",
        "description" => "Mountains at dusk"
      },
      specimen("mediumItem", "medium", "mediumFeature", %{"weight" => 1}),
      %{
        "id" => "medium",
        "component" => "Image",
        "url" => "/media/landscape.svg",
        "variant" => "mediumFeature",
        "fit" => "cover",
        "description" => "Mountains at dusk, a lake below"
      },
      label("videoLabel", "Video"),
      %{
        "id" => "video",
        "component" => "Video",
        "url" => "/media/clip.webm",
        "posterUrl" => "/media/poster.svg"
      },
      label("audioLabel", "Audio"),
      %{
        "id" => "audio",
        "component" => "AudioPlayer",
        "url" => "/media/chime.ogg",
        "description" => "A two-note chime"
      }
    ])
  end

  # A specimen: the component `child`, named under it.
  defp specimen(id, child, name, extra \\ %{}) do
    [
      Map.merge(
        %{
          "id" => id,
          "component" => "Column",
          "align" => "start",
          "children" => [child, id <> "Name"]
        },
        extra
      ),
      text(id <> "Name", name, %{"variant" => "caption"})
    ]
  end

  defp layout do
    tiles = [
      {"t1", "mail", "Inbox", "3 unread"},
      {"t2", "event", "Calendar", "2 events today"},
      {"t3", "photo", "Photos", "128 items"},
      {"t4", "folder", "Files", "All synced"}
    ]

    [
      %{
        "id" => "layoutTab",
        "component" => "Column",
        "children" => [
          "rowLabel",
          "spread",
          "weighted",
          "ruleLabel",
          "rule",
          "listLabel",
          "strip"
        ]
      },
      label("rowLabel", "Row, Column and Card"),
      %{
        "id" => "spread",
        "component" => "Row",
        "justify" => "spaceBetween",
        "align" => "center",
        "children" => ["c1", "split", "c2"]
      },
      %{"id" => "c1", "component" => "Card", "child" => "c1t"},
      text("c1t", "Card one"),
      %{"id" => "split", "component" => "Divider", "axis" => "vertical"},
      %{"id" => "c2", "component" => "Card", "child" => "c2col"},
      %{
        "id" => "c2col",
        "component" => "Column",
        "align" => "center",
        "children" => ["c2a", "c2b"]
      },
      text("c2a", "#### Card two"),
      text("c2b", "centered", %{"variant" => "caption"}),
      %{"id" => "weighted", "component" => "Row", "children" => ["w1", "w2"]},
      %{"id" => "w1", "component" => "Card", "child" => "w1t", "weight" => 1},
      text("w1t", "weight 1", %{"variant" => "caption"}),
      %{"id" => "w2", "component" => "Card", "child" => "w2t", "weight" => 2},
      text("w2t", "weight 2", %{"variant" => "caption"}),
      label("ruleLabel", "Divider"),
      %{"id" => "rule", "component" => "Divider"},
      label("listLabel", "A horizontal List of cards"),
      %{
        "id" => "strip",
        "component" => "List",
        "direction" => "horizontal",
        "children" => Enum.map(tiles, &elem(&1, 0))
      }
    ] ++
      Enum.flat_map(tiles, fn {id, icon, title, detail} ->
        [
          %{"id" => id, "component" => "Card", "child" => id <> "Body"},
          %{
            "id" => id <> "Body",
            "component" => "Column",
            "children" => [id <> "Icon", id <> "Title", id <> "Detail"]
          },
          %{"id" => id <> "Icon", "component" => "Icon", "name" => icon},
          text(id <> "Title", "#### " <> title),
          text(id <> "Detail", detail, %{"variant" => "caption"})
        ]
      end)
  end

  defp inputs do
    [
      %{
        "id" => "inputsTab",
        "component" => "Column",
        "children" => [
          "fieldsLabel",
          "name",
          "bio",
          "age",
          "secret",
          "choicesLabel",
          "subscribed",
          "toppings",
          "size",
          "country",
          "valuesLabel",
          "volume",
          "day",
          "time",
          "when",
          "echoCard"
        ]
      },
      label("fieldsLabel", "Text fields"),
      %{
        "id" => "name",
        "component" => "TextField",
        "label" => "Name",
        "value" => path("/inputs/name"),
        "placeholder" => "Your name"
      },
      %{
        "id" => "bio",
        "component" => "TextField",
        "label" => "Bio",
        "variant" => "longText",
        "value" => path("/inputs/bio")
      },
      %{
        "id" => "age",
        "component" => "TextField",
        "label" => "Age",
        "variant" => "number",
        "value" => path("/inputs/age")
      },
      %{
        "id" => "secret",
        "component" => "TextField",
        "label" => "Password",
        "variant" => "obscured",
        "value" => path("/inputs/secret")
      },
      label("choicesLabel", "Choices"),
      %{
        "id" => "subscribed",
        "component" => "CheckBox",
        "label" => "Subscribe to the newsletter",
        "value" => path("/inputs/subscribed")
      },
      %{
        "id" => "toppings",
        "component" => "ChoicePicker",
        "label" => "Toppings",
        "variant" => "multipleSelection",
        "options" => [
          %{"label" => "Basil", "value" => "basil"},
          %{"label" => "Olives", "value" => "olives"},
          %{"label" => "Chili", "value" => "chili"}
        ],
        "value" => path("/inputs/toppings")
      },
      %{
        "id" => "size",
        "component" => "ChoicePicker",
        "label" => "Size",
        "displayStyle" => "chips",
        "options" => [
          %{"label" => "Small", "value" => "small"},
          %{"label" => "Medium", "value" => "medium"},
          %{"label" => "Large", "value" => "large"}
        ],
        "value" => path("/inputs/size")
      },
      %{
        "id" => "country",
        "component" => "ChoicePicker",
        "label" => "Country",
        "filterable" => true,
        "options" =>
          for(
            {label, value} <- [
              {"France", "fr"},
              {"Germany", "de"},
              {"Italy", "it"},
              {"Japan", "jp"},
              {"Mexico", "mx"},
              {"Norway", "no"}
            ],
            do: %{"label" => label, "value" => value}
          ),
        "value" => path("/inputs/country")
      },
      label("valuesLabel", "Ranges, dates and times"),
      %{
        "id" => "volume",
        "component" => "Slider",
        "label" => "Volume",
        "min" => 0,
        "max" => 100,
        "steps" => 10,
        "value" => path("/inputs/volume")
      },
      %{
        "id" => "day",
        "component" => "DateTimeInput",
        "label" => "Day",
        "enableDate" => true,
        "value" => path("/inputs/day")
      },
      %{
        "id" => "time",
        "component" => "DateTimeInput",
        "label" => "Time",
        "enableTime" => true,
        "value" => path("/inputs/time")
      },
      %{
        "id" => "when",
        "component" => "DateTimeInput",
        "label" => "Day and time",
        "enableDate" => true,
        "enableTime" => true,
        "value" => path("/inputs/when")
      },
      %{"id" => "echoCard", "component" => "Card", "child" => "echoRow"},
      %{
        "id" => "echoRow",
        "component" => "Row",
        "align" => "center",
        "children" => ["echoIcon", "echo"]
      },
      %{"id" => "echoIcon", "component" => "Icon", "name" => "info"},
      text(
        "echo",
        call("formatString", %{
          "value" =>
            "The data model now says: ${/inputs/name}, ${/inputs/age}, newsletter ${/inputs/subscribed}, " <>
              "size ${/inputs/size}, volume ${/inputs/volume}, on ${formatDate(value: ${/inputs/when}, format: 'MMM d, HH:mm')}."
        }),
        %{
          "weight" => 1,
          "accessibility" => %{"live" => "polite", "description" => "What the inputs wrote"}
        }
      )
    ]
  end

  defp buttons do
    [
      %{
        "id" => "buttonsTab",
        "component" => "Column",
        "children" => [
          "variantLabel",
          "buttonRow",
          "callLabel",
          "linkRow",
          "modalLabel",
          "dialog"
        ]
      },
      label("variantLabel", "Variants"),
      %{
        "id" => "buttonRow",
        "component" => "Row",
        "align" => "center",
        "children" => ["plain", "primary", "borderless", "iconOnly"]
      }
    ] ++
      button("plain", "Default", event("pressed", %{"which" => "default"})) ++
      button("primary", "Primary", event("pressed", %{"which" => "primary"}), %{
        "variant" => "primary"
      }) ++
      button("borderless", "Borderless", event("pressed", %{"which" => "borderless"}), %{
        "variant" => "borderless"
      }) ++
      [
        %{
          "id" => "iconOnly",
          "component" => "Button",
          "child" => "starIcon",
          "action" => event("pressed", %{"which" => "icon"}),
          "accessibility" => %{"label" => "Star this"}
        },
        %{"id" => "starIcon", "component" => "Icon", "name" => "star"},
        label("callLabel", "A function call"),
        %{"id" => "linkRow", "component" => "Row", "children" => ["docs"]}
      ] ++
      button(
        "docs",
        "Open a2ui.org",
        %{"functionCall" => call("openUrl", %{"url" => "https://a2ui.org"})},
        %{"variant" => "borderless"}
      ) ++
      [
        label("modalLabel", "Modal"),
        %{
          "id" => "dialog",
          "component" => "Modal",
          "trigger" => "openDialog",
          "content" => "dialogBody"
        }
      ] ++
      button("openDialog", "Open a dialog", event("pressed", %{"which" => "dialog"})) ++
      [
        %{
          "id" => "dialogBody",
          "component" => "Column",
          "children" => ["dialogTitle", "dialogText"]
        },
        text("dialogTitle", "### A modal"),
        text("dialogText", "Its content is any component. Press Escape or close it to go back.")
      ]
  end

  # The agent acknowledges each press in the live region.
  def reply(%{"action" => %{"name" => "pressed", "context" => %{"which" => which}}}),
    do: [{150, data("gallery", "/lastAction", "The agent saw the #{which} button.")}]

  def reply(_message), do: []
end

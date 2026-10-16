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

  defp media do
    [
      %{
        "id" => "mediaTab",
        "component" => "Column",
        "children" => ["textHead", "body", "caption", "icons", "images", "video", "audio", "rule"]
      },
      text("textHead", "### Text"),
      text("body", "Body text with *emphasis*, **strong** words and a list:\n- one\n- two"),
      text("caption", "A caption, for the small print.", %{"variant" => "caption"}),
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
      %{
        "id" => "images",
        "component" => "Row",
        "align" => "end",
        "children" => ["avatar", "small", "medium"]
      },
      %{
        "id" => "avatar",
        "component" => "Image",
        "url" => "/media/avatar.svg",
        "variant" => "avatar",
        "description" => "A person"
      },
      %{
        "id" => "small",
        "component" => "Image",
        "url" => "/media/landscape.svg",
        "variant" => "smallFeature",
        "fit" => "cover",
        "description" => "Hills"
      },
      %{
        "id" => "medium",
        "component" => "Image",
        "url" => "/media/landscape.svg",
        "variant" => "mediumFeature",
        "fit" => "contain",
        "description" => "Hills and sun"
      },
      %{
        "id" => "video",
        "component" => "Video",
        "url" => "/media/clip.webm",
        "posterUrl" => "/media/poster.svg"
      },
      %{
        "id" => "audio",
        "component" => "AudioPlayer",
        "url" => "/media/chime.ogg",
        "description" => "A two-note chime"
      },
      %{"id" => "rule", "component" => "Divider"}
    ]
  end

  defp layout do
    [
      %{
        "id" => "layoutTab",
        "component" => "Column",
        "children" => ["rowHead", "spread", "weighted", "listHead", "strip"]
      },
      text("rowHead", "### Row, Column, Card, Divider"),
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
      text("c2a", "Card two"),
      text("c2b", "centered", %{"variant" => "caption"}),
      %{"id" => "weighted", "component" => "Row", "children" => ["w1", "w2"]},
      %{"id" => "w1", "component" => "Card", "child" => "w1t", "weight" => 1},
      text("w1t", "weight 1"),
      %{"id" => "w2", "component" => "Card", "child" => "w2t", "weight" => 2},
      text("w2t", "weight 2"),
      text("listHead", "### List"),
      %{
        "id" => "strip",
        "component" => "List",
        "direction" => "horizontal",
        "children" => ["l1", "l2", "l3", "l4"]
      },
      %{"id" => "l1", "component" => "Card", "child" => "l1t"},
      text("l1t", "First"),
      %{"id" => "l2", "component" => "Card", "child" => "l2t"},
      text("l2t", "Second"),
      %{"id" => "l3", "component" => "Card", "child" => "l3t"},
      text("l3t", "Third"),
      %{"id" => "l4", "component" => "Card", "child" => "l4t"},
      text("l4t", "Fourth")
    ]
  end

  defp inputs do
    [
      %{
        "id" => "inputsTab",
        "component" => "Column",
        "children" => [
          "name",
          "bio",
          "age",
          "secret",
          "subscribed",
          "toppings",
          "size",
          "country",
          "volume",
          "day",
          "time",
          "when",
          "echo"
        ]
      },
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
      text(
        "echo",
        call("formatString", %{
          "value" =>
            "The data model now says: ${/inputs/name}, ${/inputs/age}, newsletter ${/inputs/subscribed}, " <>
              "size ${/inputs/size}, volume ${/inputs/volume}, on ${formatDate(value: ${/inputs/when}, format: 'MMM d, HH:mm')}."
        }),
        %{"accessibility" => %{"live" => "polite", "description" => "What the inputs wrote"}}
      )
    ]
  end

  defp buttons do
    [
      %{
        "id" => "buttonsTab",
        "component" => "Column",
        "children" => ["buttonRow", "linkRow", "dialog"]
      },
      %{
        "id" => "buttonRow",
        "component" => "Row",
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
        %{"id" => "linkRow", "component" => "Row", "children" => ["docs"]}
      ] ++
      button(
        "docs",
        "Open a2ui.org",
        %{"functionCall" => call("openUrl", %{"url" => "https://a2ui.org"})},
        %{"variant" => "borderless"}
      ) ++
      [
        %{
          "id" => "dialog",
          "component" => "Modal",
          "trigger" => "openDialog",
          "content" => "dialogBody"
        }
      ] ++
      button("openDialog", "Open a dialog", event("pressed", %{"which" => "dialog"})) ++
      [
        %{"id" => "dialogBody", "component" => "Card", "child" => "dialogText"},
        text(
          "dialogText",
          "### A modal\nIts content is any component. Press Escape or close it to go back."
        )
      ]
  end

  # The agent acknowledges each press in the live region.
  def reply(%{"action" => %{"name" => "pressed", "context" => %{"which" => which}}}),
    do: [{150, data("gallery", "/lastAction", "The agent saw the #{which} button.")}]

  def reply(_message), do: []
end

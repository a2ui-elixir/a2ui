defmodule TerminalClient.RendererTest do
  use ExUnit.Case, async: true

  alias TerminalClient.{Renderer, SSE, Text}

  @basic "https://a2ui.org/specification/v1_0/catalogs/basic/catalog.json"
  @restaurant "https://example.com/a2ui/catalogs/restaurant/v1/catalog.json"

  defp create(components, data \\ %{}) do
    %{
      "version" => "v1.0",
      "createSurface" => %{
        "surfaceId" => "s",
        "catalogId" => @basic,
        "components" => components,
        "dataModel" => data
      }
    }
  end

  defp new(messages) do
    {renderer, outbound} =
      Renderer.apply(Renderer.new("v1.0", clock: fn -> ~U[2026-10-16 12:00:00Z] end), messages)

    {renderer, outbound}
  end

  test "draws the basic components and the restaurant catalog's Rating" do
    {renderer, []} =
      new([
        create(
          [
            %{
              "id" => "root",
              "component" => "Column",
              "children" => ["title", "card", "row", "line"]
            },
            %{"id" => "title", "component" => "Text", "text" => "## Hello **there**"},
            %{"id" => "card", "component" => "Card", "child" => "stars"},
            %{
              "id" => "stars",
              "component" => "Rating",
              "catalogId" => @restaurant,
              "value" => 3.6,
              "label" => "(12)"
            },
            %{"id" => "row", "component" => "Row", "children" => ["check", "pick"]},
            %{
              "id" => "check",
              "component" => "CheckBox",
              "label" => "Terrace",
              "value" => %{"@path" => "/terrace"}
            },
            %{
              "id" => "pick",
              "component" => "ChoicePicker",
              "label" => "Drink",
              "variant" => "mutuallyExclusive",
              "options" => [
                %{"label" => "Tea", "value" => "tea"},
                %{"label" => "Wine", "value" => "wine"}
              ],
              "value" => %{"@path" => "/drink"}
            },
            %{"id" => "line", "component" => "Divider"}
          ],
          %{"terrace" => true, "drink" => ["wine"]}
        )
      ])

    assert Text.render(renderer, "s") == [
             "HELLO THERE",
             "┌────────────┐",
             "│ ★★★★☆ (12) │",
             "└────────────┘",
             "[x] Terrace  Drink: ( ) Tea  (•) Wine",
             String.duplicate("─", 24)
           ]
  end

  test "typing converts what the user types for the input, and checks follow" do
    {renderer, []} =
      new([
        create(
          [
            %{"id" => "root", "component" => "Column", "children" => ["size", "name", "go"]},
            %{
              "id" => "size",
              "component" => "Slider",
              "label" => "Size",
              "min" => 1,
              "max" => 9,
              "value" => %{"@path" => "/size"}
            },
            %{
              "id" => "name",
              "component" => "TextField",
              "label" => "Name",
              "value" => %{"@path" => "/name"},
              "checks" => [
                %{
                  "condition" => %{
                    "@call" => "required",
                    "args" => %{"value" => %{"@path" => "/name"}}
                  },
                  "message" => "Required."
                }
              ]
            },
            %{
              "id" => "go",
              "component" => "Button",
              "child" => "label",
              "checks" => [
                %{
                  "condition" => %{
                    "@call" => "required",
                    "args" => %{"value" => %{"@path" => "/name"}}
                  },
                  "message" => "Name first."
                }
              ],
              "action" => %{
                "event" => %{"name" => "go", "context" => %{"size" => %{"@path" => "/size"}}}
              }
            },
            %{"id" => "label", "component" => "Text", "text" => "Go"}
          ],
          %{"size" => 1, "name" => ""}
        )
      ])

    assert "  ! Required." in Text.render(renderer, "s")
    assert {:error, "The button is disabled: its checks fail."} = Renderer.click(renderer, "Go")

    assert {:error, "Nothing labelled \"Colour\" on screen."} =
             Renderer.type(renderer, "Colour", "red")

    {:ok, renderer, []} = Renderer.type(renderer, "Size", "4")
    {:ok, renderer, []} = Renderer.type(renderer, "Name", "Ada")
    refute "  ! Required." in Text.render(renderer, "s")

    {:ok, _renderer, [action]} = Renderer.click(renderer, "Go")
    assert action["action"]["context"] == %{"size" => 4}
    assert action["action"]["timestamp"] == "2026-10-16T12:00:00Z"
  end

  test "answers the agent's calls, sends its own and puts the answers in the tree" do
    lookup = %{
      "@call" => "checkAvailability",
      "catalogId" => @restaurant,
      "args" => %{"restaurantId" => "x", "date" => "d", "partySize" => 2}
    }

    {renderer, [call, response]} =
      new([
        create([%{"id" => "root", "component" => "Text", "text" => lookup}]),
        %{
          "version" => "v1.0",
          "callRendererFunction" => %{
            "functionCallId" => "info-1",
            "callFunction" => %{
              "@call" => "clientInfo",
              "catalogId" => @restaurant,
              "args" => %{}
            }
          }
        }
      ])

    assert %{
             "callAgentFunction" => %{
               "functionCallId" => "call-1",
               "callFunction" => %{"@call" => "checkAvailability"}
             }
           } = call

    assert %{
             "rendererFunctionResponse" => %{
               "functionCallId" => "info-1",
               "value" => %{"renderer" => "terminal"}
             }
           } = response

    assert Text.render(renderer, "s") == ["…"]

    {renderer, []} =
      Renderer.apply(renderer, [
        %{
          "version" => "v1.0",
          "agentFunctionResponse" => %{"functionCallId" => "call-1", "value" => "Free at 19:30."}
        }
      ])

    assert Text.render(renderer, "s") == ["Free at 19:30."]
  end

  test "a message it cannot apply is reported to the agent" do
    {_renderer, [report]} =
      new([
        %{
          "version" => "v1.0",
          "updateDataModel" => %{"surfaceId" => "nowhere", "path" => "/a", "value" => 1}
        }
      ])

    assert %{"error" => %{"code" => "INTEGRITY_ERROR", "surfaceId" => "nowhere"}} = report
  end

  test "v0.9 states its capabilities as a client, and draws the theme's attribution" do
    renderer = Renderer.new("v0.9")
    assert %{"a2uiClientCapabilities" => %{"v0.9" => _}} = Renderer.metadata(renderer)

    {renderer, []} =
      Renderer.apply(renderer, [
        %{
          "version" => "v0.9",
          "createSurface" => %{
            "surfaceId" => "s",
            "catalogId" => "https://a2ui.org/specification/v0_9/catalogs/basic/catalog.json",
            "theme" => %{"agentDisplayName" => "Bot"}
          }
        },
        %{
          "version" => "v0.9",
          "updateComponents" => %{
            "surfaceId" => "s",
            "components" => [
              %{"id" => "root", "component" => "Text", "text" => "Hi", "variant" => "h2"}
            ]
          }
        }
      ])

    assert Text.render(renderer, "s") == ["— Bot —", "HI"]
  end

  test "server-sent events are read across chunks" do
    assert {[%{"id" => "1", "data" => "a\nb"}], "data: c"} =
             SSE.split("id: 1\ndata: a\ndata: b\n\n: comment\n\ndata: c")
  end
end

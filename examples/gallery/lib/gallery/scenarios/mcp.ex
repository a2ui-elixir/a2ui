defmodule Gallery.Scenarios.MCP do
  @moduledoc """
  The MCP catalog: buttons that call tools on an MCP server
  (`Gallery.MCPDemo`, simulated in process) with `callMcpTool`. One tool
  result carries A2UI messages, which the renderer applies; the other
  names a UI resource holding an MCP App, which `targetDataPath` writes
  into the data model for an `McpApp` to run in a sandbox. The app reads
  and writes the surface's data through `data.paths`, calls an allowed
  tool (the agent hears of it as an action), runs a host function,
  updates its model context, sends the agent a message, and is refused
  a tool it is not allowed.
  """

  use Gallery.Scenario

  alias Gallery.{Catalogs, MCPDemo}

  @mcp "https://a2ui.org/specification/v1_0/catalogs/mcp/catalog.json"

  # What the app's frame shows before the dashboard opens, in the system
  # colors of its color scheme.
  @waiting """
  <!DOCTYPE html><html><head><style>
  :root { color-scheme: light dark; font: 14px/1.5 ui-sans-serif, system-ui, sans-serif; }
  body { margin: 0; min-height: 100vh; display: grid; place-items: center; background: Canvas; color: GrayText; }
  p { max-width: 300px; margin: 0; padding: 16px; text-align: center; }
  b { color: CanvasText; font-weight: 600; }
  </style></head><body>
  <p>Press <b>Open the trip dashboard</b> to load the MCP App from its UI resource.</p>
  </body></html>
  """

  def id, do: "mcp"
  def title, do: "MCP tools and apps"

  def summary,
    do:
      "callMcpTool, A2UI messages in a tool result, an MCP App from a UI resource in a sandboxed McpApp, and the app's bridge to the surface and the agent."

  def features,
    do: [
      "MCP catalog",
      "callMcpTool",
      "A2UI in tool results",
      "UI resources",
      "targetDataPath",
      "McpApp sandbox",
      "data.paths",
      "allowedTools",
      "allowedFunctions",
      "modelContext",
      "ui/message"
    ]

  def catalogs, do: [Catalogs.basic("v1.0"), Catalogs.mcp(MCPDemo.client())]
  def session_options, do: [mcp_client: MCPDemo.client()]

  @trip %{"city" => "Lisbon", "days" => 3, "notes" => ""}

  # A sun, for Icon's svgPath.
  @sun "M11 1h2v4h-2zM11 19h2v4h-2zM1 11h4v2H1zM19 11h4v2h-4zM4.2 5.6l1.4-1.4 2.8 2.8-1.4 1.4zM15.6 17l1.4-1.4 2.8 2.8-1.4 1.4zM4.2 18.4l2.8-2.8 1.4 1.4-2.8 2.8zM15.6 7l2.8-2.8 1.4 1.4-2.8 2.8zM12 7a5 5 0 1 1 0 10 5 5 0 0 1 0-10z"

  def messages do
    [
      create("travel",
        data: %{
          "trip" => @trip,
          "weather" => %{"summary" => "No forecast yet."},
          "app" => %{"htmlContent" => @waiting},
          "context" => %{}
        },
        components: travel()
      )
    ]
  end

  defp tool(name, arguments, extra \\ %{}) do
    %{
      "functionCall" => %{
        "@call" => "callMcpTool",
        "catalogId" => @mcp,
        "args" => Map.merge(%{"name" => name, "arguments" => arguments}, extra)
      }
    }
  end

  defp travel do
    [
      %{
        "id" => "root",
        "component" => "Column",
        "children" => ["title", "intro", "city", "buttons", "trip", "context", "app"]
      },
      text("title", "## Trip planner"),
      text(
        "intro",
        "The buttons call tools on an MCP server. The weather tool's result carries A2UI messages that write " <>
          "the forecast below; the dashboard tool names a UI resource whose MCP App runs in the sandbox.",
        %{"variant" => "caption"}
      ),
      %{
        "id" => "city",
        "component" => "TextField",
        "label" => "City",
        "value" => path("/trip/city")
      },
      %{
        "id" => "buttons",
        "component" => "Row",
        "align" => "center",
        "children" => ["getWeather", "openDashboard"]
      }
    ] ++
      button(
        "getWeather",
        "Get the weather",
        tool("get_weather", %{"city" => path("/trip/city")})
      ) ++
      button(
        "openDashboard",
        "Open the trip dashboard",
        tool("open_dashboard", %{"city" => path("/trip/city")}, %{"targetDataPath" => "/app"}),
        %{"variant" => "primary"}
      ) ++
      [
        %{"id" => "trip", "component" => "Card", "child" => "tripLines"},
        %{
          "id" => "tripLines",
          "component" => "Column",
          "children" => ["weatherLine", "planLine"]
        },
        %{
          "id" => "weatherLine",
          "component" => "Row",
          "align" => "center",
          "children" => ["weatherIcon", "weather"]
        },
        %{"id" => "weatherIcon", "component" => "Icon", "name" => %{"svgPath" => @sun}},
        text("weather", path("/weather/summary"), %{
          "weight" => 1,
          "accessibility" => %{"live" => "polite"}
        }),
        %{
          "id" => "planLine",
          "component" => "Row",
          "align" => "center",
          "children" => ["planIcon", "plan"]
        },
        %{"id" => "planIcon", "component" => "Icon", "name" => "locationOn"},
        text(
          "plan",
          call("formatString", %{
            "value" => "Planned: ${/trip/days} days in ${/trip/city}. ${/trip/notes}"
          }),
          %{"weight" => 1}
        ),
        text(
          "context",
          call("formatString", %{"value" => "The app's model context: ${/context}"}),
          %{"variant" => "caption"}
        ),
        %{
          "id" => "app",
          "component" => "McpApp",
          "catalogId" => @mcp,
          "title" => "Trip dashboard",
          "htmlContent" => path("/app/htmlContent"),
          "allowedTools" => ["get_weather"],
          "allowedFunctions" => %{
            "formatString" => %{"type" => "object", "required" => ["value"]}
          },
          "data" => %{
            "paths" => %{
              "trip" => "/trip",
              "toolResult" => "/app/toolResult",
              "modelContext" => "/context"
            }
          }
        }
      ]
  end

  # A tool call the app made reaches the agent as an action named after
  # the tool; a message the app sends arrives as a ui/message action.
  def reply(%{"action" => %{"name" => "get_weather", "context" => context}}),
    do: [{200, {:text, "The dashboard checked the weather in #{context["city"]}."}}]

  def reply(%{"action" => %{"name" => "ui/message", "context" => %{"content" => content}}}) do
    asked = content |> List.wrap() |> Enum.map_join(" ", &((is_map(&1) && &1["text"]) || ""))

    [
      {300, {:text, "You asked: \"#{asked}\" Try the tile museum and a tram ride to Belém."}},
      {400, data("travel", "/trip/notes", "Ideas: tile museum, tram 28 to Belém.")}
    ]
  end

  def reply(_message), do: []

  def controls, do: [{"reset", "Reset the trip"}]
  def control("reset"), do: [{100, data("travel", "/trip", @trip)}]
  def control(_id), do: []
end

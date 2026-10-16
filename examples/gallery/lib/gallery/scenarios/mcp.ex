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

  @waiting """
  <!DOCTYPE html><html><body style="font: 14px system-ui, sans-serif; color: #5b6475; margin: 14px">
  Press <b>Open the trip dashboard</b> to load the MCP App from its UI resource.
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
        "children" => ["title", "intro", "city", "buttons", "weather", "plan", "context", "app"]
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
      %{"id" => "buttons", "component" => "Row", "children" => ["getWeather", "openDashboard"]}
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
        text("weather", path("/weather/summary"), %{"accessibility" => %{"live" => "polite"}}),
        text(
          "plan",
          call("formatString", %{
            "value" => "Planned: ${/trip/days} days in ${/trip/city}. ${/trip/notes}"
          })
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

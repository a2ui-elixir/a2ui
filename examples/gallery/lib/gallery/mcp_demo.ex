defmodule Gallery.MCPDemo do
  @moduledoc """
  A Model Context Protocol server, simulated in process, behind the
  `A2UICore.MCP.Client` behaviour: the MCP scenario's tools.

    * `get_weather` returns a forecast as text and `structuredContent`,
      and A2UI messages embedded in its content (MIME type
      `application/a2ui+json`) that write the forecast into the surface.
    * `open_dashboard` names a UI resource (`_meta.ui.resourceUri`)
      holding an MCP App (`priv/mcp/trip_dashboard.html`).
  """

  @behaviour A2UICore.MCP.Client

  @dashboard_uri "ui://trip/dashboard"
  @dashboard_path Path.expand("../../priv/mcp/trip_dashboard.html", __DIR__)
  @external_resource @dashboard_path
  @dashboard File.read!(@dashboard_path)

  @forecasts %{
    "lisbon" => {"sunny", 24},
    "paris" => {"cloudy", 17},
    "berlin" => {"showers", 14},
    "rome" => {"sunny", 26},
    "oslo" => {"cold and clear", 6}
  }

  @doc "The client, as the MCP catalog and the session take it."
  def client, do: {__MODULE__, nil}

  @doc "The URI of the dashboard's UI resource."
  def dashboard_uri, do: @dashboard_uri

  @impl true
  def list_tools(_state) do
    {:ok,
     [
       %{
         "name" => "get_weather",
         "description" => "The weather in a city.",
         "inputSchema" => %{"type" => "object"}
       },
       %{
         "name" => "open_dashboard",
         "description" => "A dashboard for a trip.",
         "inputSchema" => %{"type" => "object"},
         "_meta" => %{"ui" => %{"resourceUri" => @dashboard_uri}}
       }
     ]}
  end

  @impl true
  def call_tool(_state, "get_weather", arguments) do
    city = arguments |> Map.get("city", "") |> to_string() |> String.trim()
    {sky, temperature} = Map.get(@forecasts, String.downcase(city), {"mild", 20})
    summary = "#{city}: #{sky}, #{temperature} °C."

    messages = [
      %{
        "version" => "v1.0",
        "updateDataModel" => %{
          "surfaceId" => "travel",
          "path" => "/weather",
          "value" => %{"summary" => summary, "temperature" => temperature}
        }
      }
    ]

    {:ok,
     %{
       "content" => [
         %{"type" => "text", "text" => summary},
         %{
           "type" => "resource",
           "resource" => %{
             "uri" => "a2ui://weather/#{String.downcase(city)}",
             "mimeType" => A2UICore.MCP.mime_type(),
             "text" => Jason.encode!(messages)
           }
         }
       ],
       "structuredContent" => %{"city" => city, "sky" => sky, "temperature" => temperature}
     }}
  end

  def call_tool(_state, "open_dashboard", arguments) do
    {:ok,
     %{
       "content" => [%{"type" => "text", "text" => "The dashboard for #{arguments["city"]}."}],
       "_meta" => %{"ui" => %{"resourceUri" => @dashboard_uri}}
     }}
  end

  def call_tool(_state, name, _arguments), do: {:error, "the server has no tool #{name}"}

  @impl true
  def read_resource(_state, @dashboard_uri) do
    {:ok,
     %{
       "contents" => [
         %{
           "uri" => @dashboard_uri,
           "mimeType" => A2UICore.MCP.app_mime_type(),
           "text" => @dashboard,
           "_meta" => %{"ui" => %{"csp" => %{"connectDomains" => []}}}
         }
       ]
     }}
  end

  def read_resource(_state, uri), do: {:error, "no resource at #{uri}"}
end

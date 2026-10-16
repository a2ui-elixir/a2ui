defmodule A2UIAgent.MCPTest do
  use ExUnit.Case, async: true

  alias A2UIAgent.MCP

  doctest A2UIAgent.MCP

  @update %{
    "version" => "v1.0",
    "updateDataModel" => %{"surfaceId" => "card", "path" => "/", "value" => %{"title" => "Soup"}}
  }

  test "resources carry messages as JSON with the A2UI MIME type" do
    assert MCP.mime_type() == "application/a2ui+json"

    assert MCP.resource("a2ui://card", "Card", description: "A card.") == %{
             "uri" => "a2ui://card",
             "name" => "Card",
             "mimeType" => "application/a2ui+json",
             "description" => "A card."
           }

    contents = MCP.resource_contents("a2ui://card", [@update])
    assert %{"uri" => "a2ui://card", "mimeType" => "application/a2ui+json"} = contents
    assert Jason.decode!(contents["text"]) == [@update]
  end

  test "a tool links to the resource that presents its results" do
    assert MCP.tool("get_card") == %{"name" => "get_card", "inputSchema" => %{"type" => "object"}}

    tool =
      MCP.tool("get_card",
        title: "Get card",
        description: "Returns a card.",
        input_schema: %{"type" => "object", "properties" => %{}},
        resource_uri: "a2ui://card"
      )

    assert tool["title"] == "Get card"
    assert tool["description"] == "Returns a card."
    assert tool["inputSchema"] == %{"type" => "object", "properties" => %{}}
    assert tool["_meta"] == MCP.ui_meta("a2ui://card")
  end

  test "a tool result embeds the messages after a text fallback" do
    result =
      MCP.tool_result([@update],
        uri: "a2ui://card/data",
        text: "Here is the card.",
        resource_uri: "a2ui://card",
        audience: ["user"]
      )

    assert [
             %{"type" => "text", "text" => "Here is the card."},
             %{
               "type" => "resource",
               "resource" => %{"uri" => "a2ui://card/data", "mimeType" => "application/a2ui+json"},
               "annotations" => %{"audience" => ["user"]}
             }
           ] = result["content"]

    assert result["_meta"] == MCP.ui_meta("a2ui://card")
    assert MCP.a2ui_messages(result) == {:ok, [@update]}

    assert %{"content" => [%{"type" => "resource", "resource" => %{"uri" => "a2ui://messages"}}]} =
             MCP.tool_result([@update])
  end

  test "reading messages skips other content and reports A2UI text that is not JSON" do
    single = %{"type" => "resource", "resource" => MCP.resource_contents("a2ui://x", [])}
    single = put_in(single, ["resource", "text"], Jason.encode!(@update))
    other = %{"type" => "resource", "resource" => %{"mimeType" => "text/plain", "text" => "x"}}

    assert MCP.a2ui_messages(%{"content" => [other, single, %{"type" => "text"}]}) ==
             {:ok, [@update]}

    assert MCP.a2ui_messages(%{}) == {:ok, []}

    broken = put_in(single, ["resource", "text"], "{")
    assert {:error, %Jason.DecodeError{}} = MCP.a2ui_messages(%{"content" => [broken]})
  end

  test "renderer capabilities come from initialize or from a tool call's _meta" do
    capabilities = %{"v1.0" => %{"supportedCatalogIds" => ["basic"]}}

    assert MCP.renderer_capabilities(%{
             "capabilities" => %{"a2ui" => %{"clientCapabilities" => capabilities}}
           }) == capabilities

    assert MCP.renderer_capabilities(%{
             "name" => "tool",
             "_meta" => %{"a2ui" => %{"clientCapabilities" => capabilities}}
           }) == capabilities

    assert MCP.renderer_capabilities(%{"capabilities" => %{}}) == nil
  end

  test "the action and error tools, and reading an action" do
    assert %{"name" => "a2ui_action", "inputSchema" => %{"required" => required}} =
             MCP.action_tool()

    assert Enum.sort(required) == ~w(context name sourceComponentId surfaceId timestamp)

    assert %{
             "name" => "a2ui_error",
             "inputSchema" => %{"required" => ["code", "surfaceId", "message"]}
           } =
             MCP.error_tool()

    assert {:error, message} = MCP.action(%{"name" => "go"})
    assert message =~ "surfaceId, sourceComponentId, timestamp, context"

    arguments = %{
      "name" => "go",
      "surfaceId" => "s",
      "sourceComponentId" => "b",
      "timestamp" => "t",
      "context" => %{},
      "extra" => 1
    }

    assert {:ok, %{"version" => "v0.9", "action" => action}} = MCP.action(arguments, "v0.9")
    refute Map.has_key?(action, "extra")
  end
end

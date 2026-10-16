defmodule A2UICore.MCPTest do
  @moduledoc false
  use ExUnit.Case, async: true

  alias A2UICore.MCP

  doctest A2UICore.MCP

  @a2ui "application/a2ui+json"
  @app "text/html;profile=mcp-app"

  test "MIME types" do
    assert MCP.mime_type() == @a2ui
    assert MCP.app_mime_type() == @app
  end

  test "UI resource URIs: one or many, without blanks or duplicates" do
    meta = fn uri -> %{"_meta" => %{"ui" => %{"resourceUri" => uri}}} end

    assert MCP.ui_resource_uris(meta.(["ui://a", "", 1, "ui://b", "ui://a"])) == [
             "ui://a",
             "ui://b"
           ]

    assert MCP.ui_resource_uris(meta.(nil)) == []
    assert MCP.ui_resource_uris(nil) == []
  end

  test "messages embedded in a tool result" do
    blocks = [
      %{"type" => "text", "text" => "hi"},
      %{"type" => "resource", "resource" => %{"mimeType" => @a2ui, "text" => ~S([{"a": 1}])}},
      %{"type" => "resource", "resource" => %{"mimeType" => @a2ui, "text" => ~S({"b": 2})}},
      %{"type" => "resource", "resource" => %{"mimeType" => @a2ui, "blob" => "e30="}},
      %{"type" => "resource", "resource" => %{"mimeType" => "text/plain", "text" => "x"}}
    ]

    assert MCP.tool_result_messages(%{"content" => blocks}) == {:ok, [%{"a" => 1}, %{"b" => 2}]}
    assert MCP.tool_result_messages(%{}) == {:ok, []}
  end

  test "messages of a resource" do
    read = %{
      "contents" => [
        %{"mimeType" => @a2ui, "text" => ~S({"a": 1})},
        %{"mimeType" => @a2ui, "blob" => "e30="},
        %{"mimeType" => @app, "text" => "<p></p>"}
      ]
    }

    assert MCP.resource_messages(read, "ui://x") == {:ok, [%{"a" => 1}]}

    assert {:error, %A2UICore.Error{message: message}} =
             MCP.resource_messages(
               %{"contents" => [%{"mimeType" => @a2ui, "text" => "{"}]},
               "ui://x"
             )

    assert message ==
             "Resource ui://x declares application/a2ui+json but does not hold valid JSON."
  end

  test "the MCP App of a resource" do
    blob = %{
      "mimeType" => @app,
      "blob" => Base.encode64("<b>x</b>"),
      "_meta" => %{"ui" => %{"csp" => %{}}}
    }

    assert MCP.app_resource(%{"contents" => [blob]}) == %{
             "htmlContent" => "<b>x</b>",
             "csp" => %{}
           }

    broken = %{"mimeType" => @app, "blob" => "not base64!"}
    empty = %{"mimeType" => @app}
    assert MCP.app_resource(%{"contents" => [broken, empty, blob]})["htmlContent"] == "<b>x</b>"
    assert MCP.app_resource(%{"contents" => [%{"mimeType" => @a2ui, "text" => "{}"}]}) == nil
    assert MCP.app_resource(%{}) == nil
  end
end

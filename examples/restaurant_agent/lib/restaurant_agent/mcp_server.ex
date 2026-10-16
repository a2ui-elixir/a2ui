defmodule RestaurantAgent.MCPServer do
  @moduledoc """
  The agent as an MCP server, over MCP's JSON-RPC (one request per HTTP
  `POST`, answered with JSON). Its tools return A2UI messages in an
  embedded resource with the MIME type `application/a2ui+json`, after a
  text fallback (`A2UIAgent.MCP.tool_result/2`):

    * `find_restaurants` — `{"query": "Italian"}`, answers with the list;
    * `a2ui_action` — the renderer's users' actions;
    * `a2ui_error` — errors the renderer reports.

  The renderer states its capabilities in `initialize`, or in the
  `_meta` of each tool call. This server keeps no session, so each tool
  call carries them in its `_meta`; without them it assumes v1.0.

  MCP gives the renderer no way to answer the agent's function calls, so
  the surfaces sent this way make none.
  """

  require Logger

  alias A2UIAgent.MCP
  alias RestaurantAgent.Turns

  @protocol_version "2025-06-18"

  @doc "The JSON-RPC response to a request body, or `nil` for a notification."
  @spec handle(map()) :: map() | nil
  def handle(%{"jsonrpc" => "2.0", "method" => method, "id" => id} = request) do
    Logger.info("mcp #{method}")

    case call(method, request["params"] || %{}) do
      {:ok, result} -> %{"jsonrpc" => "2.0", "id" => id, "result" => result}
      {:error, code, message} -> error(id, code, message)
    end
  end

  def handle(%{"jsonrpc" => "2.0", "method" => _notification}), do: nil
  def handle(_other), do: error(nil, -32_600, "Invalid Request")

  defp call("initialize", params) do
    if capabilities = MCP.renderer_capabilities(params),
      do: Logger.info("mcp renderer capabilities #{inspect(Map.keys(capabilities))}")

    {:ok,
     %{
       "protocolVersion" => @protocol_version,
       "capabilities" => %{"tools" => %{"listChanged" => false}},
       "serverInfo" => %{"name" => "restaurant-finder", "version" => "0.1.0"},
       "instructions" => "Finds restaurants. Tool results carry A2UI surfaces."
     }}
  end

  defp call("ping", _params), do: {:ok, %{}}

  defp call("tools/list", _params) do
    {:ok,
     %{
       "tools" => [
         MCP.tool("find_restaurants",
           title: "Find restaurants",
           description: "Lists restaurants of a cuisine, as an A2UI surface.",
           input_schema: %{
             "type" => "object",
             "properties" => %{
               "query" => %{"type" => "string", "description" => "What to look for."}
             },
             "required" => ["query"]
           }
         ),
         MCP.action_tool(),
         MCP.error_tool()
       ]
     }}
  end

  defp call("tools/call", %{"name" => name} = params) do
    arguments = params["arguments"] || %{}
    capabilities = MCP.renderer_capabilities(params)

    with {:ok, text, events} <- tool_input(name, arguments),
         {:ok, answer} <- Turns.answer(text, events, capabilities, function_calls: false) do
      {:ok,
       MCP.tool_result(answer.messages,
         uri: "a2ui://restaurant-finder/#{name}",
         text: answer.text
       )}
    else
      {:error, :unknown_tool} ->
        {:error, -32_602, "Unknown tool: #{name}"}

      {:error, reason} ->
        {:ok, %{"content" => [%{"type" => "text", "text" => reason}], "isError" => true}}
    end
  end

  defp call(method, _params), do: {:error, -32_601, "Method not found: #{method}"}

  defp tool_input("find_restaurants", %{"query" => query}) when is_binary(query),
    do: {:ok, query, []}

  defp tool_input("find_restaurants", _arguments), do: {:error, "find_restaurants needs a query."}

  defp tool_input("a2ui_action", arguments) do
    with {:ok, action} <- MCP.action(arguments), do: {:ok, "", [action]}
  end

  defp tool_input("a2ui_error", arguments),
    do: {:ok, "", [%{"version" => "v1.0", "error" => arguments}]}

  defp tool_input(_name, _arguments), do: {:error, :unknown_tool}

  defp error(id, code, message),
    do: %{"jsonrpc" => "2.0", "id" => id, "error" => %{"code" => code, "message" => message}}
end

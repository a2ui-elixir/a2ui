defmodule A2UIAgent.MCP do
  @moduledoc """
  Carries A2UI over the [Model Context Protocol](https://modelcontextprotocol.io),
  as the A2UI project's guide "A2UI over MCP" describes: the JSON values an
  MCP server puts in its responses, and the A2UI values it reads from
  requests. It works with any MCP server implementation.

  Presentation and data are separate. Layouts (`createSurface` and
  `updateComponents` messages, with data bindings) are MCP resources with
  the MIME type `application/a2ui+json`; a tool call returns the data,
  usually an `updateDataModel` message, in an embedded resource next to a
  text fallback. A tool links to its layout with `_meta.ui`:

      A2UIAgent.MCP.tool("get_recipe", resource_uri: "a2ui://recipe-card",
        description: "Returns a recipe.")

      A2UIAgent.MCP.tool_result(messages,
        uri: "a2ui://recipe-card/data",
        resource_uri: "a2ui://recipe-card",
        text: "Generated recipe: Grilled salmon")

  A client states its renderer capabilities once in `initialize`
  (`capabilities.a2ui.clientCapabilities`), or in the `_meta` of each tool
  call; `renderer_capabilities/1` reads either. The renderer sends its
  users' actions and its errors as calls of the `a2ui_action` and
  `a2ui_error` tools (`action_tool/0`, `error_tool/0`).
  """

  @moduledoc since: "0.1.0"

  @mime_type "application/a2ui+json"
  @action_fields ~w(name surfaceId sourceComponentId timestamp context)

  @doc "The MIME type of A2UI resources: `#{@mime_type}`."
  @spec mime_type() :: String.t()
  def mime_type, do: @mime_type

  @doc """
  A resource entry for `resources/list`. Option: `:description`.

      iex> A2UIAgent.MCP.resource("a2ui://form", "Form")
      %{"uri" => "a2ui://form", "name" => "Form", "mimeType" => "application/a2ui+json"}
  """
  @spec resource(String.t(), String.t(), keyword()) :: map()
  def resource(uri, name, options \\ []) do
    %{"uri" => uri, "name" => name, "mimeType" => @mime_type}
    |> put_present("description", options[:description])
  end

  @doc """
  The contents of an A2UI resource for `resources/read`: `messages`, as
  JSON text.
  """
  @spec resource_contents(String.t(), [map()]) :: map()
  def resource_contents(uri, messages) when is_list(messages),
    do: %{"uri" => uri, "mimeType" => @mime_type, "text" => Jason.encode!(messages)}

  @doc """
  The `_meta` that links a tool, or a tool's result, to the A2UI resource
  that presents it.

      iex> A2UIAgent.MCP.ui_meta("a2ui://recipe-card")
      %{"ui" => %{"resourceUri" => "a2ui://recipe-card", "mimeType" => "application/a2ui+json"}}
  """
  @spec ui_meta(String.t()) :: map()
  def ui_meta(resource_uri),
    do: %{"ui" => %{"resourceUri" => resource_uri, "mimeType" => @mime_type}}

  @doc """
  A tool definition for `tools/list`. Options: `:title`,
  `:description`, `:input_schema` (default: an object that takes any
  arguments) and `:resource_uri`, the A2UI resource that presents its
  results.
  """
  @spec tool(String.t(), keyword()) :: map()
  def tool(name, options \\ []) do
    %{"name" => name, "inputSchema" => options[:input_schema] || %{"type" => "object"}}
    |> put_present("title", options[:title])
    |> put_present("description", options[:description])
    |> put_present("_meta", options[:resource_uri] && ui_meta(options[:resource_uri]))
  end

  @doc """
  A tool call's result (`CallToolResult`) carrying A2UI messages in an
  embedded resource.

  Options:

    * `:uri` — the embedded resource's URI (default `"a2ui://messages"`);
    * `:text` — a text fallback, put first, for clients and models that
      do not render A2UI;
    * `:resource_uri` — the A2UI resource that presents the result,
      linked with `_meta.ui`;
    * `:audience` — who the messages are for: `["user"]` renders them
      without putting them in the model's context, `["assistant"]` the
      other way round (default: both).
  """
  @spec tool_result([map()], keyword()) :: map()
  def tool_result(messages, options \\ []) when is_list(messages) do
    resource = resource_contents(options[:uri] || "a2ui://messages", messages)

    embedded =
      %{"type" => "resource", "resource" => resource}
      |> put_present("annotations", options[:audience] && %{"audience" => options[:audience]})

    text = if options[:text], do: [%{"type" => "text", "text" => options[:text]}], else: []

    %{"content" => text ++ [embedded]}
    |> put_present("_meta", options[:resource_uri] && ui_meta(options[:resource_uri]))
  end

  @doc """
  The A2UI messages in a tool call's result: the JSON of every embedded
  resource with the A2UI MIME type, in order. Content that is not A2UI
  is skipped; A2UI text that is not JSON is an error.
  """
  @spec a2ui_messages(map()) :: {:ok, [map()]} | {:error, Jason.DecodeError.t()}
  def a2ui_messages(%{} = result) do
    (result["content"] || [])
    |> Enum.flat_map(fn
      %{"type" => "resource", "resource" => %{"mimeType" => @mime_type, "text" => text}} -> [text]
      _other -> []
    end)
    |> Enum.reduce_while({:ok, []}, fn text, {:ok, messages} ->
      case Jason.decode(text) do
        {:ok, list} when is_list(list) -> {:cont, {:ok, messages ++ list}}
        {:ok, message} -> {:cont, {:ok, messages ++ [message]}}
        {:error, error} -> {:halt, {:error, error}}
      end
    end)
  end

  @doc """
  The renderer capabilities in the params of an `initialize` request
  (`capabilities.a2ui.clientCapabilities`) or of a tool call
  (`_meta.a2ui.clientCapabilities`), keyed by protocol version, or `nil`
  when they carry none. Pass them to
  `A2UIAgent.Generator.create_processor/3`.
  """
  @spec renderer_capabilities(map()) :: map() | nil
  def renderer_capabilities(%{} = params) do
    get_in(params, ["capabilities", "a2ui", "clientCapabilities"]) ||
      get_in(params, ["_meta", "a2ui", "clientCapabilities"])
  end

  @doc """
  The definition of the `a2ui_action` tool, through which a renderer
  sends its users' actions. Every field of an action is required, so
  that an MCP SDK does not drop one.
  """
  @spec action_tool() :: map()
  def action_tool do
    tool("a2ui_action",
      description: "Handles an action a user took on an A2UI surface.",
      input_schema: %{
        "type" => "object",
        "properties" => %{
          "name" => %{"type" => "string", "description" => "The action's name."},
          "surfaceId" => %{"type" => "string", "description" => "The surface it came from."},
          "sourceComponentId" => %{
            "type" => "string",
            "description" => "The component that triggered it."
          },
          "timestamp" => %{"type" => "string", "description" => "When it happened (ISO 8601)."},
          "context" => %{"type" => "object", "description" => "The action's resolved context."}
        },
        "required" => @action_fields
      }
    )
  end

  @doc "The definition of the `a2ui_error` tool, through which a renderer reports errors."
  @spec error_tool() :: map()
  def error_tool do
    tool("a2ui_error",
      description: "Handles an error a renderer reports for an A2UI surface.",
      input_schema: %{
        "type" => "object",
        "properties" => %{
          "code" => %{"type" => "string", "description" => "The error code."},
          "surfaceId" => %{"type" => "string", "description" => "The surface it concerns."},
          "message" => %{"type" => "string", "description" => "What went wrong."},
          "path" => %{"type" => "string", "description" => "The JSON pointer it concerns."}
        },
        "required" => ["code", "surfaceId", "message"]
      }
    )
  end

  @doc """
  The arguments of an `a2ui_action` tool call as an A2UI `action`
  message of `version`, or an error naming the missing fields.

      iex> A2UIAgent.MCP.action(%{"name" => "go", "surfaceId" => "s", "sourceComponentId" => "b",
      ...>   "timestamp" => "2026-10-16T12:00:00Z", "context" => %{}})
      {:ok, %{"version" => "v1.0", "action" => %{"name" => "go", "surfaceId" => "s",
        "sourceComponentId" => "b", "timestamp" => "2026-10-16T12:00:00Z", "context" => %{}}}}
  """
  @spec action(map(), String.t()) :: {:ok, map()} | {:error, String.t()}
  def action(%{} = arguments, version \\ "v1.0") do
    case Enum.reject(@action_fields, &Map.has_key?(arguments, &1)) do
      [] ->
        {:ok, %{"version" => version, "action" => Map.take(arguments, @action_fields)}}

      missing ->
        {:error, "an a2ui_action call needs #{Enum.join(missing, ", ")}"}
    end
  end

  defp put_present(map, _key, nil), do: map
  defp put_present(map, key, value), do: Map.put(map, key, value)
end

defmodule A2UICore.MCP do
  @moduledoc """
  Reading A2UI out of [Model Context Protocol](https://modelcontextprotocol.io)
  values: the A2UI messages a tool result or a resource carries, the UI
  resources a tool or a result names, and the MCP Apps a resource holds.

  A2UI travels in MCP as JSON text with the MIME type
  `application/a2ui+json`, either embedded in a tool result's content or
  in a resource; a tool or a result names its UI resources in
  `_meta.ui.resourceUri` (one URI or a list). An
  [MCP App](https://github.com/modelcontextprotocol/ext-apps) is HTML
  with the MIME type `text/html;profile=mcp-app`, and its resource's
  `_meta.ui` may carry `csp` and `permissions` for the sandbox that runs
  it.
  """

  alias A2UICore.Error

  @moduledoc since: "0.1.0"

  @mime_type "application/a2ui+json"
  @app_mime_type "text/html;profile=mcp-app"

  @doc "The MIME type of A2UI content: `#{@mime_type}`."
  @spec mime_type() :: String.t()
  def mime_type, do: @mime_type

  @doc "The MIME type of MCP App HTML: `#{@app_mime_type}`."
  @spec app_mime_type() :: String.t()
  def app_mime_type, do: @app_mime_type

  @doc """
  The UI resource URIs a tool descriptor or a tool result names in
  `_meta.ui.resourceUri`, without duplicates.

      iex> A2UICore.MCP.ui_resource_uris(%{"_meta" => %{"ui" => %{"resourceUri" => "ui://card"}}})
      ["ui://card"]
      iex> A2UICore.MCP.ui_resource_uris(%{"content" => []})
      []
  """
  @spec ui_resource_uris(map() | nil) :: [String.t()]
  def ui_resource_uris(%{} = source) do
    source
    |> get_in(["_meta", "ui", "resourceUri"])
    |> List.wrap()
    |> Enum.filter(&(is_binary(&1) and &1 != ""))
    |> Enum.uniq()
  end

  def ui_resource_uris(_source), do: []

  @doc """
  The A2UI messages embedded in a tool result's content: the JSON of
  every `resource` block with the A2UI MIME type, in order. A block whose
  text is not JSON is an error.
  """
  @spec tool_result_messages(map()) :: {:ok, [map()]} | {:error, Error.t()}
  def tool_result_messages(%{} = result) do
    (result["content"] || [])
    |> Enum.flat_map(fn
      %{"type" => "resource", "resource" => %{"mimeType" => @mime_type} = resource} ->
        if is_binary(resource["text"]), do: [{resource["uri"], resource["text"]}], else: []

      _other ->
        []
    end)
    |> decode_all()
  end

  @doc """
  The A2UI messages of a `resources/read` result: the JSON of every
  content with the A2UI MIME type, in order.
  """
  @spec resource_messages(map(), String.t()) :: {:ok, [map()]} | {:error, Error.t()}
  def resource_messages(%{} = read_result, uri) do
    read_result
    |> contents(@mime_type)
    |> Enum.map(&{uri, &1["text"]})
    |> Enum.filter(fn {_uri, text} -> is_binary(text) end)
    |> decode_all()
  end

  @doc """
  The MCP App in a `resources/read` result, or `nil`: the HTML of its
  first content with the MCP App MIME type (`text`, or base64 `blob`),
  with the `csp` and `permissions` of that content's `_meta.ui`.

      iex> A2UICore.MCP.app_resource(%{"contents" => [
      ...>   %{"uri" => "ui://game", "mimeType" => "text/html;profile=mcp-app", "text" => "<p>Hi</p>"}
      ...> ]})
      %{"htmlContent" => "<p>Hi</p>"}
  """
  @spec app_resource(map()) :: map() | nil
  def app_resource(%{} = read_result) do
    Enum.find_value(contents(read_result, @app_mime_type), fn content ->
      with html when is_binary(html) <- html(content) do
        ui = get_in(content, ["_meta", "ui"]) || %{}

        %{"htmlContent" => html}
        |> put_present("csp", ui["csp"])
        |> put_present("permissions", ui["permissions"])
      end
    end)
  end

  defp contents(read_result, mime_type) do
    for %{"mimeType" => ^mime_type} = content <- read_result["contents"] || [], do: content
  end

  defp html(%{"text" => text}) when is_binary(text), do: text

  defp html(%{"blob" => blob}) when is_binary(blob) do
    case Base.decode64(blob) do
      {:ok, html} -> html
      :error -> nil
    end
  end

  defp html(_content), do: nil

  defp decode_all(texts) do
    Enum.reduce_while(texts, {:ok, []}, fn {uri, text}, {:ok, messages} ->
      case Jason.decode(text) do
        {:ok, list} when is_list(list) ->
          {:cont, {:ok, messages ++ list}}

        {:ok, message} ->
          {:cont, {:ok, messages ++ [message]}}

        {:error, _reason} ->
          {:halt,
           {:error,
            Error.new(
              :expression,
              "EXPRESSION_ERROR",
              "Resource #{uri} declares #{@mime_type} but does not hold valid JSON."
            )}}
      end
    end)
  end

  defp put_present(map, _key, nil), do: map
  defp put_present(map, key, value), do: Map.put(map, key, value)
end

defmodule A2UICore.Functions.MCP do
  @moduledoc """
  Implementations of the MCP catalog's functions (see
  `A2UICore.Catalog.MCP`).

    * `callMcpTool` calls a tool through the host's
      `A2UICore.MCP.Client` and returns the tool's `CallToolResult`.
      The A2UI messages the result carries — in the UI resources it
      names (`_meta.ui.resourceUri`, else those its tool descriptor
      declares) and embedded in its content — come back as
      `{:messages, %{messages: messages, source: :resource | :inline}}`
      effects for the renderer to apply; messages without a `version`
      get the catalog's (`v0.9` or `v1.0`). With `targetDataPath` (v1.0),
      the MCP App a resource holds is written there as
      `%{"uri", "htmlContent", "csp", "permissions", "toolInput", "toolResult"}`
      (a `{:write, ...}` effect), ready for an `McpApp` component to
      bind.
    * `jmespath` evaluates a JMESPath expression (`A2UICore.JMESPath`).
    * `split`, `regexCapture` and `regexReplace` work on a string, or on
      each string of an array. Patterns are RE2 expressions, run by PCRE
      with RE2's meaning of `$` (end of text) and ASCII `\\d`, `\\w`, `\\b`.
    * `updateDataModel` asks for its updates to be written: one
      `{:write, %{path: path, value: value}}` effect per entry, the path
      resolved against the calling scope.

  Effects reach the renderer from an action (see
  `A2UICore.Resolution.NodeResolver.invoke/5`); a renderer applies them
  in order. Failures are errors with category `:expression`.
  """

  alias A2UICore.{Coerce, Error, JMESPath, MCP, SemVer}
  alias A2UICore.Resolution.DataContext

  @moduledoc since: "0.1.0"

  @typedoc "The MCP client: `{module, state}`, or a function from a tool name to one."
  @type client :: MCP.Client.t() | (String.t() -> MCP.Client.t() | nil)

  @doc """
  The function implementations of the MCP catalog of `version`.

  Options: `:client` — the `t:client/0` `callMcpTool` uses. Without one,
  `callMcpTool` fails.
  """
  @spec implementations(String.t(), keyword()) :: %{
          optional(String.t()) => A2UICore.Catalog.Function.execute()
        }
  def implementations(version, options \\ []) do
    message_version = if SemVer.at_least(version, "v1.0"), do: "v1.0", else: "v0.9"
    client = Keyword.get(options, :client)

    %{
      "callMcpTool" => fn args, ctx -> call_mcp_tool(args, ctx, client, message_version) end,
      "jmespath" => fn args, _ctx -> jmespath(args) end,
      "split" => fn args, _ctx -> split(args) end,
      "regexCapture" => fn args, _ctx -> regex_capture(args) end,
      "regexReplace" => fn args, _ctx -> regex_replace(args) end,
      "updateDataModel" => fn args, ctx -> update_data_model(args, ctx) end
    }
  end

  # -- callMcpTool --------------------------------------------------------------

  defp call_mcp_tool(args, ctx, client, message_version) do
    name = Coerce.to_string(args["name"])
    arguments = args["arguments"] || %{}

    with {:ok, {module, state}} <- client_for(client, name),
         {:ok, result} <- call_tool(module, state, name, arguments),
         {:ok, resources} <- read_ui_resources(module, state, name, result),
         {:ok, inline} <- MCP.tool_result_messages(result) do
      effects =
        Enum.flat_map(resources, &message_effects(&1.messages, :resource, message_version)) ++
          app_effects(resources, args, ctx, arguments, result) ++
          message_effects(inline, :inline, message_version)

      {:ok, result, effects}
    else
      {:error, reason} ->
        {:error, expression_error("Failed to execute MCP tool '#{name}': #{describe(reason)}")}
    end
  end

  defp client_for({module, _state} = client, _name) when is_atom(module), do: {:ok, client}
  defp client_for(module, _name) when is_atom(module) and module != nil, do: {:ok, {module, nil}}

  defp client_for(resolver, name) when is_function(resolver, 1) do
    case resolver.(name) do
      {module, _state} = client when is_atom(module) -> {:ok, client}
      module when is_atom(module) and module != nil -> {:ok, {module, nil}}
      _none -> no_client(name)
    end
  end

  defp client_for(_none, name), do: no_client(name)

  defp no_client(name), do: {:error, "MCP client for tool '#{name}' could not be resolved."}

  defp call_tool(module, state, name, arguments) do
    case guarded(fn -> module.call_tool(state, name, arguments) end) do
      {:ok, nil} ->
        {:error, "MCP tool '#{name}' did not return a result."}

      {:ok, %{"isError" => true} = result} ->
        {:error, "MCP tool '#{name}' execution failed: #{Jason.encode!(result)}"}

      {:ok, %{} = result} ->
        {:ok, result}

      {:error, reason} ->
        {:error, reason}

      other ->
        {:error, "MCP tool '#{name}' returned #{inspect(other)}"}
    end
  end

  # The URIs the result names win over those the tool declares.
  defp read_ui_resources(module, state, name, result) do
    uris =
      case MCP.ui_resource_uris(result) do
        [] -> declared_uris(module, state, name)
        named -> named
      end

    if uris != [] and exports?(module, :read_resource, 2),
      do: read_all(module, state, uris),
      else: {:ok, []}
  end

  defp read_all(module, state, uris) do
    Enum.reduce_while(uris, {:ok, []}, fn uri, {:ok, acc} ->
      case read_resource(module, state, uri) do
        {:ok, entry} -> {:cont, {:ok, acc ++ [entry]}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp read_resource(module, state, uri) do
    with {:ok, %{} = read} <- guarded(fn -> module.read_resource(state, uri) end),
         {:ok, messages} <- MCP.resource_messages(read, uri) do
      {:ok, %{uri: uri, messages: messages, app: MCP.app_resource(read)}}
    else
      {:error, reason} -> {:error, reason}
      other -> {:error, "reading #{uri} returned #{inspect(other)}"}
    end
  end

  # A failed `tools/list` only means there is no declared resource.
  defp declared_uris(module, state, name) do
    with true <- exports?(module, :list_tools, 1),
         {:ok, tools} when is_list(tools) <- guarded(fn -> module.list_tools(state) end),
         %{} = tool <- Enum.find(tools, &(is_map(&1) and &1["name"] == name)) do
      MCP.ui_resource_uris(tool)
    else
      _none -> []
    end
  end

  defp message_effects([], _source, _version), do: []

  defp message_effects(messages, source, version),
    do: [{:messages, %{messages: Enum.map(messages, &with_version(&1, version)), source: source}}]

  defp app_effects(resources, args, ctx, arguments, result) do
    with target when is_binary(target) and target != "" <- args["targetDataPath"],
         %{uri: uri, app: app} <- Enum.find(resources, &is_map(&1.app)) do
      payload = Map.merge(%{"uri" => uri, "toolInput" => arguments, "toolResult" => result}, app)
      [{:write, %{path: DataContext.resolve_path(ctx, target), value: payload}}]
    else
      _none -> []
    end
  end

  defp with_version(%{} = message, version) do
    if message["version"] == nil, do: Map.put(message, "version", version), else: message
  end

  defp with_version(message, _version), do: message

  defp exports?(module, function, arity),
    do: Code.ensure_loaded?(module) and function_exported?(module, function, arity)

  defp guarded(callback) do
    callback.()
  rescue
    exception -> {:error, exception}
  end

  # -- data functions -----------------------------------------------------------

  defp jmespath(%{"expression" => expression} = args) when is_binary(expression) do
    case JMESPath.search(expression, args["data"]) do
      {:ok, value} ->
        {:ok, value}

      {:error, error} ->
        {:error, expression_error("#{error.message} in JMESPath expression: #{expression}")}
    end
  end

  defp jmespath(args),
    do:
      {:error,
       expression_error("jmespath expects a string expression, got #{kind(args["expression"])}.")}

  defp split(args) do
    separator = Coerce.to_string(args["separator"])
    {:ok, over_value(args["value"], &split_text(&1, separator))}
  end

  defp split_text(text, ""), do: String.codepoints(text)
  defp split_text(text, separator), do: String.split(text, separator)

  # PCRE leaves out the unmatched groups at the end of a match; a final
  # empty group, which always matches, keeps them all (as "").
  defp regex_capture(args) do
    with {:ok, regex} <- re2(args["pattern"], "regexCapture") do
      capture =
        case Regex.compile("(?:" <> regex.source <> ")()", regex.opts) do
          {:ok, padded} -> &drop_last(Regex.run(padded, &1, capture: :all_but_first))
          {:error, _reason} -> &Regex.run(regex, &1, capture: :all_but_first)
        end

      {:ok, over_value(args["value"], capture)}
    end
  end

  defp drop_last(nil), do: nil
  defp drop_last(groups), do: Enum.drop(groups, -1)

  defp regex_replace(args) do
    with {:ok, regex} <- re2(args["pattern"], "regexReplace") do
      replacement = Coerce.to_string(args["replacement"])
      {:ok, over_value(args["value"], &Regex.replace(regex, &1, fn _match -> replacement end))}
    end
  end

  defp re2(pattern, function) do
    source = Coerce.to_string(pattern)

    case Regex.compile(source, [:unicode, :dollar_endonly]) do
      {:ok, regex} ->
        {:ok, regex}

      {:error, {reason, at}} ->
        {:error,
         expression_error(
           "Invalid RE2 pattern '#{source}' in #{function}: #{reason} at position #{at}"
         )}
    end
  end

  defp over_value(values, fun) when is_list(values),
    do: Enum.map(values, &fun.(Coerce.to_string(&1)))

  defp over_value(value, fun), do: fun.(Coerce.to_string(value))

  defp update_data_model(%{"updates" => %{} = updates}, ctx) do
    writes =
      for {path, value} <- updates do
        {:write, %{path: DataContext.resolve_path(ctx, path), value: value}}
      end

    {:ok, nil, writes}
  end

  defp update_data_model(%{"updates" => nil}, _ctx), do: {:ok, nil}
  defp update_data_model(args, _ctx) when not is_map_key(args, "updates"), do: {:ok, nil}

  defp update_data_model(%{"updates" => other}, _ctx) do
    {:error,
     expression_error(
       "updateDataModel expects an object of data model paths, got #{kind(other)}."
     )}
  end

  # -- helpers ------------------------------------------------------------------

  defp kind(nil), do: "null"
  defp kind(value) when is_list(value), do: "an array"
  defp kind(value) when is_map(value), do: "an object"
  defp kind(value) when is_boolean(value), do: "a boolean"
  defp kind(value) when is_number(value), do: "a number"
  defp kind(_value), do: "a string"

  defp describe(reason) when is_binary(reason), do: reason
  defp describe(%{__exception__: true} = exception), do: Exception.message(exception)
  defp describe(reason), do: inspect(reason)

  defp expression_error(message), do: Error.new(:expression, "EXPRESSION_ERROR", message)
end

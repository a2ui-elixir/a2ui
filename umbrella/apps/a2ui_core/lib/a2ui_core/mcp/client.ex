defmodule A2UICore.MCP.Client do
  @moduledoc """
  A connection to a [Model Context Protocol](https://modelcontextprotocol.io)
  server, as the MCP catalog's functions use it.

  `A2UICore` makes no MCP connections itself: the host implements this
  behaviour over whatever MCP client it uses and passes the client as
  `{module, state}` (see `A2UICore.Catalog.MCP.catalog/2`). Every callback
  receives the `state`; values are MCP's JSON objects with string keys.

    * `c:call_tool/3` sends `tools/call` and returns the `CallToolResult`.
    * `c:read_resource/2` sends `resources/read` and returns its result
      (`%{"contents" => [...]}`); without it, the UI resources a tool
      names are not read.
    * `c:list_tools/1` sends `tools/list` and returns the tools; without
      it, a tool's declared UI resource (`_meta.ui.resourceUri` in its
      descriptor) is not looked up.

  A callback returns `{:error, reason}` on failure; `reason` is a string,
  an exception or any term, and becomes part of the function's error
  message. Results are not cached between calls; a client that wants
  caching (`tools/list` rarely changes) does it itself.
  """

  @moduledoc since: "0.1.0"

  @typedoc "A client: its module and the state passed to every callback."
  @type t :: {module(), term()}

  @doc "Calls the tool `name` with `arguments`."
  @callback call_tool(state :: term(), name :: String.t(), arguments :: map()) ::
              {:ok, map() | nil} | {:error, term()}

  @doc "Reads the resource at `uri`."
  @callback read_resource(state :: term(), uri :: String.t()) :: {:ok, map()} | {:error, term()}

  @doc "Lists the server's tools."
  @callback list_tools(state :: term()) :: {:ok, [map()]} | {:error, term()}

  @optional_callbacks read_resource: 2, list_tools: 1
end

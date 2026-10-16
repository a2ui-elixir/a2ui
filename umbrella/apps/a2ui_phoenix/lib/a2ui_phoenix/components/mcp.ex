defmodule A2UIPhoenix.Components.MCP do
  @moduledoc """
  The function component for the MCP catalog's `McpApp` (v1.0): an
  [MCP App](https://github.com/modelcontextprotocol/ext-apps) running in
  a double-iframe sandbox, connected to the surface over the MCP Apps
  JSON-RPC bridge.

  The component renders a container with the `A2UIMcpApp` hook
  (`priv/static/a2ui_phoenix.js`). The hook loads the sandbox proxy page
  (`priv/static/a2ui_mcp_sandbox.html`, at the URL given by the surface's
  `:mcp_sandbox` assign, `#{inspect("/a2ui_phoenix/a2ui_mcp_sandbox.html")}` by default),
  hands it the app's HTML with its CSP domains and permissions, answers
  the app's handshake, resizes the frame, keeps the app's bound state
  (`data.paths`) in step with the data model, and passes the requests
  that concern the surface to `A2UIPhoenix.Session.mcp_app_request/5`.
  """

  use Phoenix.Component

  import A2UIPhoenix.Components, only: [text: 1]

  alias A2UICore.Resolution.DataContext
  alias A2UIPhoenix.{Context, MCPApp}

  @moduledoc since: "0.1.0"

  @default_sandbox "/a2ui_phoenix/a2ui_mcp_sandbox.html"

  @doc "The MCP catalog's components by type."
  @spec components() :: %{String.t() => (map() -> Phoenix.LiveView.Rendered.t())}
  def components, do: %{"McpApp" => &mcp_app/1}

  @doc "The sandbox proxy URL used when the surface sets none: `#{@default_sandbox}`."
  @spec default_sandbox() :: String.t()
  def default_sandbox, do: @default_sandbox

  @doc "`McpApp`: the app's sandbox frame."
  @spec mcp_app(map()) :: Phoenix.LiveView.Rendered.t()
  def mcp_app(assigns) do
    %{ctx: ctx, node: node, props: props} = assigns
    context = DataContext.for_surface(ctx.surface, path: node.data_path)

    assigns =
      assign(assigns,
        html: MCPApp.html(props),
        title: if(props["title"] in [nil, ""], do: "MCP App", else: text(props["title"])),
        state: Jason.encode!(MCPApp.state(props, ctx.surface, context)),
        csp: Jason.encode!(map_or_empty(props["csp"])),
        permissions: Jason.encode!(map_or_empty(props["permissions"])),
        sandbox: ctx.mcp_sandbox || @default_sandbox
      )

    ~H"""
    <div
      {@attrs}
      class="a2ui-mcp-app"
      phx-hook="A2UIMcpApp"
      phx-target={@ctx.target}
      data-surface={@ctx.surface_id}
      data-ref={@node.ref}
      data-sandbox={@sandbox}
      data-title={@title}
      data-html={@html}
      data-csp={@csp}
      data-permissions={@permissions}
      data-state={@state}
    >
      <div
        id={Context.dom_id(@ctx, @node, "frame")}
        class="a2ui-mcp-app-frame"
        data-a2ui-mcp-frame
        phx-update="ignore"
      >
      </div>
    </div>
    """
  end

  defp map_or_empty(%{} = map), do: map
  defp map_or_empty(_other), do: %{}
end

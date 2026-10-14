# A2UIPhoenix

A Phoenix LiveView renderer for [A2UI](https://a2ui.org) surfaces, built on
`a2ui_core`. It renders the basic catalog (protocol v0.9.1 and v1.0) as
function components, keeps two-way bindings in the surface's data model, and
turns user actions into renderer→agent messages.

## Usage

```elixir
defmodule MyAppWeb.AgentLive do
  use MyAppWeb, :live_view

  alias A2UIPhoenix.{Live, Session}

  def mount(_params, _session, socket) do
    session = Session.new([A2UICore.Catalog.Basic.catalog("v1.0")])
    {:ok, Live.init(socket, session, on_send: &send_to_agent/2)}
  end

  # Messages from the agent, however they arrive (SSE, A2A, a process).
  def handle_info({:agent, payload}, socket) do
    {_result, socket} = Live.handle_message(socket, payload)
    {:noreply, socket}
  end

  def render(assigns) do
    ~H"""
    <.live_component
      :for={surface <- Session.surfaces(@a2ui)}
      module={A2UIPhoenix.Surface}
      id={"surface-" <> surface.id}
      session={@a2ui}
      surface_id={surface.id}
    />
    """
  end

  defp send_to_agent(message, socket) do
    # Deliver `message` (an `action`, `error` or `rendererFunctionResponse`).
    socket
  end
end
```

Add `priv/static/a2ui_phoenix.js` to the page's scripts so `openUrl` actions
open their URL, and `priv/static/a2ui_phoenix.css` (or your own styles for the
`a2ui-*` classes) for layout.

A catalog of your own brings its components as a map:

```heex
<.live_component module={A2UIPhoenix.Surface} components={%{"Chart" => &chart/1}} ... />
```

Each component receives `@ctx`, `@node`, `@props` (bindings resolved),
`@a11y` and `@attrs`; see `A2UIPhoenix.Components`.

## Streaming to other renderers

`A2UIPhoenix.Plug.SSE` streams A2UI messages to a renderer outside LiveView,
such as a web renderer in the browser, as server-sent events, one message per
event:

```elixir
# In a controller:
def events(conn, params), do: A2UIPhoenix.Plug.SSE.stream(conn, MyAgent.messages(params))

# Or mounted in a router, with the source called for each request:
forward "/a2ui/events", A2UIPhoenix.Plug.SSE, source: {MyAgent, :messages, []}
```

## License

Apache-2.0

# Rendering surfaces

`a2ui_phoenix` draws A2UI surfaces in a Phoenix LiveView. The agent's
messages build the surfaces, the user's input flows back into their data
models, and the user's actions become messages for the agent. Underneath it
is `a2ui_core`, whose
[processing guide](https://hexdocs.pm/a2ui_core/processing_messages.html) covers
the protocol itself.

## Setup

```elixir
def deps do
  [
    {:a2ui_phoenix, "~> 0.1.0"}
  ]
end
```

The package ships two assets in `priv/static`:

- `a2ui_phoenix.css` lays out the basic components. It uses the
  `--a2ui-*` custom properties of the reference web renderer for colors and
  spacing, so you can theme it by setting those properties.
- `a2ui_phoenix.js` opens the URLs that `openUrl` actions ask for, and holds
  the hook of the MCP catalog's `McpApp` component (see
  [MCP tools and apps](#mcp-tools-and-apps)).

In a project created with `mix phx.new`, import them from your assets:

```javascript
// assets/js/app.js
import "a2ui_phoenix/priv/static/a2ui_phoenix.js"
```

```css
/* assets/css/app.css */
@import "../../deps/a2ui_phoenix/priv/static/a2ui_phoenix.css";
```

The basic `Icon` component renders Material Icons ligatures
(`<i class="material-icons">`). Load that font, for example from Google
Fonts, for icons to show.

## The session

An `A2UIPhoenix.Session` is the renderer's state for one conversation: the
surfaces the agent built and the resolved component tree of each. Like
everything in `a2ui_core`, it is a plain value. Each call returns the next
session and a list of effects for the host:

```elixir
alias A2UICore.Resolution.NodeResolver
alias A2UIPhoenix.Session

basic = A2UICore.Catalog.Basic.catalog("v1.0")
session = Session.new([basic], clock: fn -> ~U[2026-10-14 12:00:00Z] end)

{:ok, session, effects} =
  Session.handle_message(session, [
    %{
      "version" => "v1.0",
      "createSurface" => %{"surfaceId" => "main", "catalogId" => basic.catalog_id}
    },
    %{
      "version" => "v1.0",
      "updateDataModel" => %{"surfaceId" => "main", "path" => "/name", "value" => ""}
    },
    %{
      "version" => "v1.0",
      "updateComponents" => %{
        "surfaceId" => "main",
        "components" => [
          %{"id" => "root", "component" => "Column", "children" => ["name", "send"]},
          %{
            "id" => "name",
            "component" => "TextField",
            "label" => "Name",
            "value" => %{"@path" => "/name"}
          },
          %{
            "id" => "send",
            "component" => "Button",
            "child" => "sendLabel",
            "action" => %{
              "event" => %{"name" => "submit", "context" => %{"name" => %{"@path" => "/name"}}}
            }
          },
          %{"id" => "sendLabel", "component" => "Text", "text" => "Send"}
        ]
      }
    }
  ])

effects
#=> [
#=>   {:surface_created, "main"},
#=>   {:data_model_updated, "main", "/name"},
#=>   {:components_updated, "main", ["root", "name", "send", "sendLabel"]}
#=> ]
```

The tree of a surface is an `A2UICore.Resolution.NodeResolver`. User input
names a node by its `ref`. Typing into the text field writes through its
two-way binding:

```elixir
positions = session |> Session.resolver("main") |> NodeResolver.positions()
name_field = positions["root/children/0"]

{:ok, session, effects} = Session.write(session, "main", name_field.ref, "value", "Ada")

effects
#=> [{:data_model_updated, "main", "/name"}]
```

Pressing the button invokes its action, which produces a `{:send, message}`
effect: a message for the agent.

```elixir
send_button = positions["root/children/1"]
{:ok, session, [send: message]} = Session.invoke(session, "main", send_button.ref, "action")

message
#=> %{
#=>   "version" => "v1.0",
#=>   "action" => %{
#=>     "name" => "submit",
#=>     "surfaceId" => "main",
#=>     "sourceComponentId" => "send",
#=>     "timestamp" => "2026-10-14T12:00:00Z",
#=>     "context" => %{"name" => "Ada"}
#=>   }
#=> }
```

A message the session cannot apply returns `{:error, error, session, effects}`.
The returned session keeps whatever was applied before the failure. When the
error concerns a surface, the effects include the `error` message to report
to the agent:

```elixir
{:error, _error, session, [send: report]} =
  Session.handle_message(session, %{
    "version" => "v1.0",
    "updateDataModel" => %{"surfaceId" => "other", "path" => "/x", "value" => 1}
  })

report
#=> %{
#=>   "version" => "v1.0",
#=>   "error" => %{
#=>     "code" => "INTEGRITY_ERROR",
#=>     "message" => "Surface not found for message: other",
#=>     "surfaceId" => "other"
#=>   }
#=> }
```

| Effect | What the host does |
|---|---|
| `{:send, message}` | delivers `message` (`action`, `error`, `rendererFunctionResponse`) to the agent |
| `{:open_url, url}` | opens `url` in the browser |
| `{:diagnostic, surface_id, level, payload}` | logs a problem found while resolving (an unknown component type, a binding to a missing path) |
| `{:surface_created, id}` and the other processor effects | nothing required; see `A2UICore.Processor` |

## In a LiveView

`A2UIPhoenix.Live` keeps the session in an assign and delivers its effects.
`A2UIPhoenix.Surface` is the LiveComponent that draws one surface:

```elixir
defmodule MyAppWeb.AgentLive do
  use MyAppWeb, :live_view

  alias A2UIPhoenix.{Live, Session}

  def mount(_params, _session, socket) do
    session = Session.new([A2UICore.Catalog.Basic.catalog("v1.0")])
    {:ok, Live.init(socket, session, on_send: &send_to_agent/2)}
  end

  # Messages from the agent, however they arrive.
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

  # Messages for the agent (`action`, `error`, `rendererFunctionResponse`),
  # here broadcast to the process that talks to it.
  defp send_to_agent(message, socket) do
    Phoenix.PubSub.broadcast(MyApp.PubSub, "a2ui:renderer", {:renderer, self(), message})
    socket
  end
end
```

`A2UIPhoenix.Live.init/3` assigns the session (as `@a2ui` by default) and
attaches a hook that applies what the surfaces report: input reaching a
two-way binding and actions the user triggers. The LiveView does not handle
those events itself. Effects are delivered as they happen:

- `{:send, message}` goes to the `:on_send` callback, your transport to the
  agent;
- `{:open_url, url}` is pushed to the browser, where `a2ui_phoenix.js` opens
  it;
- every other effect goes to the `:on_effect` callback, when you give one.

Local UI state, such as the open tab or an open modal, lives in the
`A2UIPhoenix.Surface` component and never reaches the agent.

## Talking to the agent

The session does not know the transport. In the example above, renderer
messages are broadcast on the `"a2ui:renderer"` topic together with the
LiveView's pid. Whatever process talks to the agent subscribes to that topic
and answers with `send(pid, {:agent, payload})`. Agent payloads can come from
anywhere, for example a client reading an A2A stream, whose parts
[`A2UIAgent.A2A.a2ui_messages/1`](https://hexdocs.pm/a2ui_agent/A2UIAgent.A2A.html#a2ui_messages/1)
turns into messages.

Each message to the agent should carry what the renderer supports, and the
data models of surfaces created with `"sendDataModel" => true`:

```elixir
session = A2UIPhoenix.Live.session(socket)
{:ok, capabilities} = A2UICore.Processor.renderer_capabilities(session.processor, versions: ["v1.0"])
{:ok, data_model} = A2UIPhoenix.Session.client_data_model(session)
```

Over A2A these travel in the message metadata, as `a2uiRendererCapabilities`
and `a2uiRendererDataModel` (`a2uiClientCapabilities` and
`a2uiClientDataModel` in protocol v0.9).

## MCP tools and apps

The A2UI MCP catalog lets a surface call
[Model Context Protocol](https://modelcontextprotocol.io) tools and embed
[MCP Apps](https://github.com/modelcontextprotocol/ext-apps). Add it next to
the basic catalog. `a2ui_core` makes no MCP connections itself: wrap your MCP
client in a module implementing `A2UICore.MCP.Client`, and give it to the
catalog (for `callMcpTool`) and to the session (for the tools an embedded app
calls):

```elixir
defmodule MyApp.Weather do
  @behaviour A2UICore.MCP.Client

  @impl true
  def call_tool(_state, "get_weather", %{"city" => city}) do
    {:ok, %{"content" => [%{"type" => "text", "text" => "Sunny in #{city}"}]}}
  end
end

client = {MyApp.Weather, nil}

session =
  A2UIPhoenix.Session.new(
    [A2UICore.Catalog.Basic.catalog("v1.0"), A2UICore.Catalog.MCP.catalog("v1.0", client: client)],
    mcp_client: client
  )
```

A component or a function call names the MCP catalog by `catalogId`. When an
action calls `callMcpTool`, `A2UIPhoenix.Session.invoke/4` applies what the
tool returns: the A2UI messages embedded in its result or held by the UI
resource it names (`_meta.ui.resourceUri`), and, with `targetDataPath`, the
MCP App that resource holds, written there for an `McpApp` to bind.

### Embedding MCP Apps

`McpApp` runs an app in a double-iframe sandbox: an outer frame loads the
sandbox proxy page, which runs the app in an inner frame without
`allow-same-origin`, under a Content Security Policy that blocks network
connections beyond the domains the app declares, with sensitive browser
features denied unless the component delegates them. Register the hook with
your LiveSocket:

```javascript
// assets/js/app.js
import "a2ui_phoenix/priv/static/a2ui_phoenix.js"

let liveSocket = new LiveSocket("/live", Socket, {
  hooks: {...window.A2UIPhoenix.hooks},
  params: {_csrf_token: csrfToken}
})
```

and serve the proxy page from the package's `priv/static`:

```elixir
# lib/my_app_web/endpoint.ex
plug Plug.Static,
  at: "/a2ui_phoenix",
  from: {:a2ui_phoenix, "priv/static"},
  only: ["a2ui_mcp_sandbox.html"]
```

For stronger isolation, serve the page from an origin of its own and pass its
URL as the `mcp_sandbox` assign of `A2UIPhoenix.Surface`.

The hook answers the app's handshake, display mode and link requests
(`http` and `https` only) in the browser, resizes the frame (within 200-3000
by 100-2000 pixels), and keeps the values the component binds in
`data.paths` in step with the data model. What concerns the surface goes to
`A2UIPhoenix.Session.mcp_app_request/5`: a tool call the component allows in
`allowedTools` reaches the agent as an action named after the tool (and runs
through the session's `:mcp_client`, whose result the app gets); a function
the component lists in `allowedFunctions` runs once its arguments pass the
schema given there; the app's data changes are written to the bound paths.
Payloads with prototype keys, deeper than 10 levels or larger than 64 KiB are
refused.

## Components of your own

A catalog of your own needs a function component for each of its component
types. A component receives these assigns:

- `@props`: the node's properties, with every binding replaced by its
  current value;
- `@node`: the `A2UICore.Resolution.Node`;
- `@ctx`: the `A2UIPhoenix.Context` of the surface;
- `@attrs`: the attributes for the component's root element (its DOM id,
  `data-a2ui-id` and the ARIA attributes the component declared);
- `@a11y`: the component's accessibility attributes.

```elixir
defmodule MyAppWeb.A2UIComponents do
  use Phoenix.Component

  alias A2UIPhoenix.{Components, Context}

  # A label with a tone: "info", "success" or "warning".
  def badge(assigns) do
    ~H"""
    <span class={["badge", "badge-#{@props["tone"]}"]} {@attrs}>{@props["label"]}</span>
    """
  end

  # A container: children are rendered with Components.child/1.
  def panel(assigns) do
    ~H"""
    <section class="panel" {@attrs}>
      <h2>{@props["title"]}</h2>
      <Components.child ctx={@ctx} child={@props["child"]} />
    </section>
    """
  end

  # An input: named with Context.input_name/2, it writes the property it names.
  def note(assigns) do
    ~H"""
    <textarea name={Context.input_name(@node, "text")} {@attrs}>{@props["text"]}</textarea>
    """
  end
end
```

Pass the components to each surface, by type, and the catalog to the
session:

```heex
<.live_component
  :for={surface <- Session.surfaces(@a2ui)}
  module={A2UIPhoenix.Surface}
  id={"surface-" <> surface.id}
  session={@a2ui}
  surface_id={surface.id}
  components={%{
    "Badge" => &MyAppWeb.A2UIComponents.badge/1,
    "Panel" => &MyAppWeb.A2UIComponents.panel/1,
    "Note" => &MyAppWeb.A2UIComponents.note/1
  }}
/>
```

Your map is merged over `A2UIPhoenix.Components.Basic.components/0`, so the
same map can also replace a basic component. A component type with no
function renders a placeholder.

An input's value reaches the data model only when the property it names is
bound to a data path, as in `"text" => %{"@path" => "/note"}`. The submitted
string is written as it is. `A2UIPhoenix.Inputs` shows how the basic
components convert theirs.

## Streaming to other renderers

`A2UIPhoenix.Plug.SSE` streams A2UI messages to a renderer outside LiveView,
such as a web renderer in the browser, as server-sent events, one message
per event:

```elixir
# In a controller:
def events(conn, params), do: A2UIPhoenix.Plug.SSE.stream(conn, MyAgent.messages(params))

# Or mounted in a router, with the source called for each request:
forward "/a2ui/events", A2UIPhoenix.Plug.SSE, source: {MyAgent, :messages, []}
```

The messages can be any enumerable, including a lazy stream. The response
ends when the enumerable does or when the client goes away.

A message given as `{id, message}` is sent with an `id:` line. A browser's
`EventSource` that loses the connection reconnects with the last id it
received in the `Last-Event-ID` header, and
`A2UIPhoenix.Plug.SSE.last_event_id/1` reads it, so that the source can
continue after that message. The `:retry` option sets how long the browser
waits before it reconnects.

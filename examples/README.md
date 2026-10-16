# Examples

Three applications that use the packages together, each with its own tests.

| Example | What it is | Run it |
|---|---|---|
| [`restaurant_agent`](restaurant_agent/README.md) | An agent that finds restaurants and books tables with A2UI surfaces, served over A2A, MCP, AG-UI, server-sent events and WebSocket. Built with `a2ui_agent`. | `mix run --no-halt` → <http://127.0.0.1:4001> |
| [`gallery`](gallery/README.md) | A Phoenix LiveView app built with `a2ui_phoenix`: ten scripted scenarios that cover the protocol, the 43 reference examples, a live chat with the restaurant agent, and a LiveDashboard. | `mix phx.server` → <http://localhost:4000> |
| [`terminal_client`](terminal_client/README.md) | A renderer that draws surfaces as text, built on `a2ui_core` alone, with a client for every transport the agent serves. | `mix chat "Find Italian restaurants"` |

`catalogs/restaurant_catalog.json` is the catalog the agent and both renderers
share: a `Rating` component, the agent-side function `checkAvailability`, and
`clientInfo`, which the renderers implement and only the agent may call.

## Trying everything

Each example depends on the packages in `../umbrella` by path, so the commands
below run against the code in this repository. Elixir 1.18 or later.

```bash
# 1. The agent
cd examples/restaurant_agent
mix deps.get
mix run --no-halt                    # http://127.0.0.1:4001

# 2. The gallery, in another terminal
cd examples/gallery
mix deps.get
mix phx.server                       # http://localhost:4000, chat at /chat

# 3. The terminal client, in a third
cd examples/terminal_client
mix deps.get
mix chat --stream "Find Italian restaurants" "click:Book a table" \
  "type:Your name=Ada" "type:Email=ada@example.com" "click:Confirm booking"
```

The gallery's reference-examples page reads the upstream checkout described in
the repository's README (`reference/a2ui`, or `A2UI_REFERENCE_ROOT`).

## Tests

```bash
(cd examples/restaurant_agent && mix test)   # every transport, a full booking through a real renderer session
(cd examples/terminal_client && mix test)    # the renderer, and a chat over each transport against the agent
(cd examples/gallery && mix test)            # every scenario, every reference example, the chat against a live agent, the landing page's replays
```

The tests start what they need: the terminal client's and the gallery's start
the restaurant agent in process on a free port.

## What is exercised where

| Feature | Where |
|---|---|
| v1.0 messages: `createSurface` with components and data, `updateComponents`, `updateDataModel` (path, root, delete), `deleteSurface` | gallery: Surfaces, Data; agent: every answer |
| v0.9 messages, the v0.9 theme (`primaryColor`, `agentDisplayName`, `iconUrl`) | gallery: Protocol v0.9; agent and terminal client with `--version v0.9` |
| The 18 components of the basic catalog, Markdown in `Text`, accessibility attributes | gallery: Components, and the reference examples |
| Two-way bindings, also inside templates | gallery: Components, Forms, Data, MCP |
| Checks with `required`, `regex`, `length`, `numeric`, `email`, `and`, `or`, `not`; buttons disabled by checks | gallery: Forms, Protocol v0.9; the agent's booking form |
| List templates, relative and absolute paths, nested templates, `@index`, `formatString`, `formatNumber`, `formatCurrency`, `formatDate`, `pluralize` | gallery: Data; the agent's list and confirmation |
| Actions: events with context and `userMessage`, function-call actions, `openUrl` | gallery: Surfaces, Functions |
| `sendDataModel`: data models in the transport metadata | gallery: Forms, Surfaces, Protocol v0.9; the chat |
| Catalogs of your own, `catalogId` per component and per call, inline catalogs in the capabilities | gallery: Custom catalogs; the restaurant catalog everywhere |
| Agent functions (`callAgentFunction`, `agentFunctionResponse`), the busy state, errors and timeouts | gallery: Functions; the agent's `checkAvailability` |
| Renderer functions (`callRendererFunction`, `rendererFunctionResponse`), `allowedCallers`, `requiresUserActivation` | gallery: Functions, Errors; the agent's `clientInfo` |
| `error` messages: validation, integrity, unknown surfaces and catalogs, versions, reserved keys; diagnostics; recovery | gallery: Errors |
| Streaming: the direct JSON parser building a surface chunk by chunk; Express, read whole | gallery: Streaming; agent: `/a2a` (`message/stream`) and `/a2a/express` |
| The MCP catalog: `callMcpTool`, A2UI in tool results, UI resources, `McpApp` in a sandbox and its bridge | gallery: MCP; agent: `/mcp` |
| Transports: A2A (`message/send`, `message/stream`), MCP, AG-UI, server-sent events with resumption, WebSocket | agent and terminal client; the gallery's chat (A2A) |
| Agent SDK: catalog negotiation from the renderer's capabilities, prompts, validated parsing, the builder, a component macro (`RestaurantCard`), Express | agent: `RestaurantAgent.Catalogs`, `UI`, `Model`; `/prompt` shows the system prompt |
| Monitoring: telemetry per message, LiveDashboard, request logs | gallery: `/dashboard` |

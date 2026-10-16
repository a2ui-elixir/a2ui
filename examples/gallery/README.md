# A2UI gallery

A Phoenix LiveView application built with `a2ui_phoenix` that shows what the
protocol can do and how the renderer handles it.

```bash
mix deps.get
mix phx.server       # http://localhost:4000; PORT overrides
mix test
```

| Page | |
|---|---|
| `/` | The scenarios. |
| `/scenarios/:id` | A scenario: a scripted agent, the surfaces it builds, controls that make it act, and an inspector with every message in both directions, each surface's data model, the renderer's capabilities and the agent's script. |
| `/examples` | The 43 example surfaces of the A2UI project, from the upstream checkout (`reference/a2ui`, or `A2UI_REFERENCE_ROOT`), with what each would send. |
| `/chat` | A conversation with the restaurant agent over A2A (`AGENT_URL`, `http://127.0.0.1:4001` by default; start it first, see `../restaurant_agent`). |
| `/dashboard` | Phoenix LiveDashboard, with the gallery's metrics: A2UI messages by direction, kind and page, and how long each took to handle. |

## Scenarios

| Scenario | What it shows |
|---|---|
| Component gallery | All 18 components of the basic catalog, their variants and accessibility attributes, two-way bindings, a modal; buttons whose actions the agent answers. |
| Forms and validation | Checks on every input, a button enabled only when they pass, `sendDataModel`, a reply that swaps the form for a summary and back. |
| Data binding | Templates over lists, relative and absolute paths, a nested template, `@index`, the formatting functions, quotes pushed to single paths every second, a deleted binding. |
| Surfaces | Surfaces created with their components and data, opened and closed by the agent; components replaced, added and changed in type; `userMessage`; `openUrl`. |
| Functions and RPC | Calls the renderer sends to the agent and their answers, errors and timeouts; a function-call action; calls the agent sends to the renderer, allowed and refused. |
| Custom catalogs | The gallery's own catalog (`priv/catalogs/widgets_catalog.json`: `Badge`, `Progress`, `Panel`, `initials`) next to the basic and restaurant catalogs, `catalogId` per component and per call. |
| Streaming | A model's answer parsed chunk by chunk with `A2UIAgent.DirectJson.Parser`: the surface builds while the text arrives. The same answer in Express, read whole. |
| MCP tools and apps | `callMcpTool` against a simulated MCP server (`Gallery.MCPDemo`), A2UI messages in a tool result, an MCP App from a UI resource running in `McpApp`'s sandbox, and the app's bridge to the surface and the agent. |
| Errors and recovery | Faulty messages of every kind: what the renderer rejects, what it reports to the agent, and how the agent recovers. |
| Protocol v0.9 | The v0.9 wire format on the same renderer, with the surface theme v0.9 defines. |

A scenario is a module implementing `Gallery.Scenario` (`lib/gallery/scenarios`):
the agent's first messages, its replies to what the renderer sends, and its
controls.

## Design

The pages and the surfaces they show are one design. Surfaces are drawn by
`a2ui_phoenix.css`, the renderer's design system; the pages are made of the
gallery's UI kit, `GalleryWeb.CoreComponents` (page header, panels, buttons,
badges, tabs, the frame a surface is shown in, the message log, chat
bubbles, callouts), styled by `priv/static/assets/gallery.css` with the same
`--a2ui-*` tokens. The gallery sets a few of them (the Geist fonts, bundled
in `priv/static/assets/fonts` under the SIL Open Font License, and its
primary color) and the page's `color-scheme`, which the header's switch
turns to light or dark. Icons are Material Symbols, from Google Fonts. The
components of the gallery's own catalogs (`Rating`, `Badge`, `Progress`,
`Panel`) are styled by `priv/static/assets/catalog.css`, with the same
tokens, and the scenarios compose their surfaces with the patterns the
examples share (`../README.md`). The trip dashboard of the MCP scenario
(`priv/mcp/trip_dashboard.html`) takes its light or dark theme from the
host context the renderer sends it.

## Replays for the landing page

The landing page (`../../site`) is static, so it plays recordings instead of
running the gallery. `mix gallery.replays` makes them: it runs the restaurant
agent's booking conversation (over A2A, in process), the Streaming scenario
and the Forms scenario against an `A2UIPhoenix.Session`, renders every surface
with `A2UIPhoenix.Surface` after each step, and writes the steps with the
messages that crossed to `../../site/priv/replays.json`, next to copies of the
stylesheets they are drawn with, the renderer's and `catalog.css`
(`--site DIR` writes elsewhere). The recorder lives in
`test/support/replays` and the task runs in the test environment, where the
restaurant agent is a dependency.

`mix test` checks that the site holds a fresh recording: a change to the
agent, a scenario or the renderer that shows in a replay fails until the
replays are recorded again.

# Restaurant agent

An A2UI agent built with `a2ui_agent`: it finds restaurants and books tables,
and answers with A2UI surfaces. A scripted model stands in for an LLM, so the
agent runs offline and answers the same way every time; everything around the
model is what a real agent does: it negotiates catalogs from the renderer's
capabilities, gives the model a system prompt, parses and validates what the
model writes (streamed, in the direct JSON or the Express format), and answers
actions and function calls.

```bash
mix deps.get
mix run --no-halt        # http://127.0.0.1:4001; PORT and PUBLIC_URL override
mix test
```

## The conversation

1. Ask for a cuisine: "Find Italian restaurants" (Italian, Japanese, Mexican,
   Indian and French places are known). The agent answers with a list built
   with the `RestaurantCard` component macro, which shows the restaurant
   catalog's `Rating`.
2. "Book a table" opens a form. It asks the agent whether a table is free with
   the agent function `checkAvailability` (the renderer sends
   `callAgentFunction`), and the agent asks the renderer for its time zone with
   the renderer function `clientInfo` (`callRendererFunction`).
3. "Confirm booking" replaces the form with a confirmation; "Done" closes it.

The same conversation works in protocol v0.9 (a themed surface, no functions)
when the renderer only supports v0.9.

## Endpoints

| Path | What it serves |
|---|---|
| `GET /.well-known/agent-card.json` | The A2A agent card, advertising the A2UI extension for v1.0 and v0.9. |
| `POST /a2a` | A2A JSON-RPC: `message/send`, and `message/stream`, whose server-sent events carry the answer as the model writes it. |
| `POST /a2a/express` | The same, with the model writing the Express format. |
| `POST /mcp` | MCP JSON-RPC: the tool `find_restaurants`, whose result embeds A2UI messages, and the tools `a2ui_action` and `a2ui_error` that bring actions and errors back. |
| `POST /agui` | AG-UI: a `RunAgentInput` answered with server-sent events; each surface is an activity snapshot. |
| `GET /events?q=…` | Plain server-sent events, one A2UI message each, resumable with `Last-Event-ID`. |
| `GET /ws` | WebSocket: JSON frames in both directions. |
| `GET /prompt` | The system prompt the agent gives its model (`?format=express`, `?version=v0.9`). |
| `GET /images/:id.svg` | The restaurants' pictures. |

The renderer states its capabilities with every message: in A2A, in the
message metadata as `a2uiRendererCapabilities`. Without them the agent
explains that it needs an A2UI renderer:

```bash
curl -s http://127.0.0.1:4001/a2a \
  -H 'content-type: application/json' \
  -H 'x-a2a-extensions: https://a2ui.org/a2a-extension/a2ui/v1.0' \
  -d '{"jsonrpc": "2.0", "id": 1, "method": "message/send", "params": {"message": {
        "kind": "message", "messageId": "m1", "role": "user",
        "parts": [{"kind": "text", "text": "Find Mexican restaurants"}],
        "metadata": {"a2uiRendererCapabilities": {"v1.0": {"supportedCatalogIds": [
          "https://a2ui.org/specification/v1_0/catalogs/basic/catalog.json",
          "https://example.com/a2ui/catalogs/restaurant/v1/catalog.json"]}}}}}}'
```

```bash
curl -N 'http://127.0.0.1:4001/events?q=Find%20French%20restaurants'

curl -s http://127.0.0.1:4001/mcp -H 'content-type: application/json' \
  -d '{"jsonrpc": "2.0", "id": 1, "method": "tools/call",
       "params": {"name": "find_restaurants", "arguments": {"query": "Find Indian restaurants"}}}'
```

To talk to it through a renderer, use the gallery's chat page or the terminal
client (`../README.md`).

## Code

| Module | Role |
|---|---|
| `RestaurantAgent.Catalogs` | The catalogs the agent offers (basic and restaurant), the `RestaurantCard` macro, and the prompt generators. |
| `RestaurantAgent.Model` | The scripted model: what it writes for each turn, in direct JSON or Express, and how it streams. |
| `RestaurantAgent.UI` | Surfaces built in code with `A2UIAgent.Builder`: the booking form, the confirmation, the v0.9 list. |
| `RestaurantAgent.Turn` | One turn of the conversation, shared by every transport: text, actions, function calls and responses. |
| `RestaurantAgent.Agent`, `ExpressAgent` | The A2A agents (`A2UIAgent.A2A.Agent`). |
| `RestaurantAgent.MCPServer`, `AGUIServer`, `Socket`, `Turns` | The other transports. |
| `RestaurantAgent.Router` | The HTTP endpoints. |

# Terminal client

An A2UI renderer that draws surfaces as text, built on `a2ui_core` alone: the
processor applies the agent's messages, the node resolver gives the component
tree, and `TerminalClient.Text` draws it. It answers what a renderer answers
(actions, function calls and responses, errors) and talks to the restaurant
agent over every transport it serves.

```bash
mix deps.get
mix chat "Find Italian restaurants" "click:Book a table" \
  "type:Your name=Ada" "type:Email=ada@example.com" "click:Confirm booking"
mix test
```

Each argument is a step: text to say, `click:LABEL` (`click:LABEL#1` for the
second button with that label) or `type:LABEL=VALUE`. Without steps, `mix chat`
reads them from standard input, one per line, until an empty line.

| Option | |
|---|---|
| `--transport` | `a2a` (default), `express` (A2A, the model writes Express), `mcp`, `agui`, `sse` (one way: the first answer only) or `ws` |
| `--url` | the agent's base URL, `http://127.0.0.1:4001` by default |
| `--version` | `v1.0` (default) or `v0.9` |
| `--stream` | A2A's `message/stream` instead of `message/send` |

```text
> click "Confirm booking"
agent: Done! Your table at Ramen-ya is booked.

[booking-m2-2440]
(check)
TABLE BOOKED
Ada, we expect you at Ramen-ya on Saturday, October 17 at 19:30.
A table for 2.
────────────────────────
[ Done ]
```

## Code

| Module | Role |
|---|---|
| `TerminalClient.Renderer` | The renderer: `A2UICore.Processor` and `A2UICore.Resolution.NodeResolver`, agent function calls, renderer function responses, error reports, clicks and typing by label. |
| `TerminalClient.Text` | Draws a resolved tree as text, the restaurant catalog's `Rating` included. |
| `TerminalClient.Chat` | Runs the steps: sends what the user and the surfaces say, and draws what changed. |
| `TerminalClient.Transports.*` | A2A, MCP, AG-UI, server-sent events and WebSocket clients behind `TerminalClient.Transport`. |

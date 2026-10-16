# Changelog

## 0.1.0 (unreleased)

First release.

- `A2UIPhoenix.Session`: the renderer state of one conversation, as plain
  data.
- `A2UIPhoenix.Live` and `A2UIPhoenix.Surface`: surfaces in a LiveView, with
  two-way bindings, actions and local UI state.
- The basic catalog's components (protocol v0.9.1 and v1.0) as function
  components with ARIA attributes.
- A design system for them (`priv/static/a2ui_phoenix.css`): tokens named as
  in the reference web renderers (`--a2ui-color-primary`, type scale, space,
  radii, shadows, motion, per-component tokens), light and dark through the
  page's `color-scheme` or the `a2ui-light`/`a2ui-dark` classes, colors
  derived from the primary color on each surface, one anatomy for every
  input (label, control, messages of failed checks, read as guidance while
  the field is empty, `data-a2ui-empty`), states as ARIA attributes, and
  Material Symbols icons.
- Components of other catalogs, passed to a surface by type.
- The MCP catalog: actions that call MCP tools apply what the tools return,
  and `McpApp` embeds MCP Apps in a double-iframe sandbox
  (`A2UIPhoenix.Components.MCP`, the `A2UIMcpApp` hook,
  `priv/static/a2ui_mcp_sandbox.html`, `A2UIPhoenix.Session.mcp_app_request/5`).
- `A2UIPhoenix.Plug.SSE`: A2UI messages streamed as server-sent events,
  with event ids, a reconnection delay and the client's `Last-Event-ID` for
  resuming a stream.
- Agent functions: a call the surface cannot run goes to the agent as
  `callAgentFunction`, its answer is applied when it arrives, and a call that
  fails or times out (`A2UIPhoenix.Session.timeout_agent_call/2`, timed by
  `A2UIPhoenix.Live`) is reported as a diagnostic. A component waiting for an
  answer has `aria-busy="true"`.
- The v0.9 surface theme: `primaryColor` sets `--a2ui-color-primary`, and the
  agent's name and icon are shown above the surface.
- A validation error reported to the agent names the field that failed, as
  a JSON Pointer into the message (`/components/0/text`).
- `DateTimeInput` shows a date unless only the time is enabled
  (`A2UIPhoenix.Inputs.date_enabled?/1`).
- Stylesheet: image sizes per variant, dividers, full-width media, a busy
  indicator, Markdown text without outer margins, and a slider whose track
  fills to its value (`--a2ui-slider-fill`).

# Changelog

## 0.1.0 (unreleased)

First release.

- `A2UIPhoenix.Session`: the renderer state of one conversation, as plain
  data.
- `A2UIPhoenix.Live` and `A2UIPhoenix.Surface`: surfaces in a LiveView, with
  two-way bindings, actions and local UI state.
- The basic catalog's components (protocol v0.9.1 and v1.0) as function
  components with ARIA attributes, and a stylesheet that uses the reference
  web renderer's custom properties.
- Components of other catalogs, passed to a surface by type.
- `A2UIPhoenix.Plug.SSE`: A2UI messages streamed as server-sent events,
  with event ids, a reconnection delay and the client's `Last-Event-ID` for
  resuming a stream.

# Changelog

## 0.1.0 (unreleased)

First release.

- Protocol versions v0.9, v0.9.1 and v1.0: agent-to-renderer messages
  decoded into version-neutral operations and encoded back, validated against
  the specification's JSON schemas.
- Catalogs: catalog documents loaded and made self-contained, the basic
  catalog of each version with its functions implemented, composition
  constraints, and `en-US` formatting behind a pluggable
  `A2UICore.Formatter`.
- `A2UICore.Processor`: surfaces, components and data models updated by
  messages, with strict or relaxed validation of the component graph and
  effects returned as data.
- Expressions, data bindings and function calls
  (`A2UICore.Expression`, `A2UICore.Resolution.DataContext`).
- `A2UICore.Resolution.NodeResolver`: the resolved component tree a renderer
  draws, with stable node identity, placeholders and change notifications.
- Accessibility attributes and checks (`A2UICore.Accessibility`).
- Function calls between renderer and agent in protocol v1.0, as a state
  machine without processes (`A2UICore.RPC`).
- Renderer capabilities, renderer data models and renderer-to-agent messages.

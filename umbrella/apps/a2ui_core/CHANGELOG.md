# Changelog

## 0.1.0 (unreleased)

First release.

- Protocol versions v0.9, v0.9.1 and v1.0: agent-to-renderer messages
  decoded into version-neutral operations and encoded back, validated against
  the specification's JSON schemas.
- Catalogs: catalog documents read into a model and written back
  (`A2UICore.Catalog.to_json/2`, in the document's key order on request), the
  self-contained schema messages are validated against, references into
  peer catalogs, the basic catalog of each version with its functions
  implemented, composition constraints, and `en-US` formatting behind a
  pluggable `A2UICore.Formatter`.
- `A2UICore.Processor`: surfaces, components and data models updated by
  messages, with strict or relaxed validation of the component graph and
  effects returned as data. From v1.0 each component and function call runs
  in the catalog it names, or in its surface's default catalog, which a
  surface may leave out.
- Expressions, data bindings and function calls
  (`A2UICore.Expression`, `A2UICore.Resolution.DataContext`).
- `A2UICore.Resolution.NodeResolver`: the resolved component tree a renderer
  draws, with stable node identity, placeholders and change notifications.
- Accessibility attributes and checks (`A2UICore.Accessibility`).
- Function calls between renderer and agent in protocol v1.0, as a state
  machine without processes (`A2UICore.RPC`).
- Renderer capabilities, renderer data models and renderer-to-agent messages.

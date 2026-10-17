# Changelog

## 0.1.1 (2026-10-17)

- Compiles on Elixir 1.17: the message operation structs come before the
  module that matches on them, which Elixir 1.17 needs.
- Regular expressions match the same on every Erlang/OTP release. `\d`,
  `\w` and `\b` are spelled out as ASCII classes, since the PCRE of
  Erlang/OTP 27 and earlier counts Latin-1 letters such as `é` as word
  characters. There, `XID_Start` and `XID_Continue` now include the
  Other_ID_Start and Other_ID_Continue characters (`℘`, `·`), and
  `\p{Script=Greek}` and `\p{sc=Greek}` compile.

## 0.1.0 (2026-10-17)

First release.

- Protocol versions v0.9, v0.9.1 and v1.0: agent-to-renderer messages
  decoded into version-neutral operations and encoded back, validated against
  the specification's JSON schemas.
- Catalogs: catalog documents read into a model and written back
  (`A2UICore.Catalog.to_json/2`, in the document's key order on request), the
  self-contained schema messages are validated against, references into
  peer catalogs (inlined with `A2UICore.Catalog.inline_refs/4`, which also
  keeps key order), the basic catalog of each version with its functions
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
- `A2UICore.Schema`, a JSON Schema draft 2020-12 validator that passes every
  required test of the official JSON Schema Test Suite, with ECMA-262 regular
  expressions (`A2UICore.Schema.ECMA262`). Catalog names are UAX #31
  identifiers, checked with PCRE2's XID properties.
- The MCP catalog (`A2UICore.Catalog.MCP`, v0.9 and v1.0): `callMcpTool` through
  a host-provided `A2UICore.MCP.Client`, and the v0.9 data functions, with
  `A2UICore.JMESPath` behind `jmespath`. Functions can return data model writes
  and A2UI messages as effects, which reach the renderer from actions.
- Agent functions (v1.0): a function call that no catalog of the surface can
  run locally is routed to the agent (`DataContext`'s `:agent_calls`), and the
  node resolver keeps the calls it sent, their answers, and which nodes wait
  on one (`Node.busy`).
- Who may call a function, inside the renderer: functions reserved for the
  agent (`allowedCallers: "agentOnly"`), and functions that need a user gesture
  (`requiresUserActivation`) outside an action, are expression errors.
- `formatString` templates call system functions (`${@index(offset: 1)}`);
  `formatDate` reads timestamps without seconds, as `fromisoformat` does, and
  takes text in single quotes literally, as TR35 patterns do.
- `A2UICore.KeyOrder.message/1` orders a message's keys as the protocol's
  schemas list them.
- Regular-expression searches (the basic catalog's `regex` check, a schema's
  `pattern`) stop after a million backtracking steps with a `REGEX_LIMIT`
  error, so a pattern an agent or a catalog supplies cannot keep the host busy.

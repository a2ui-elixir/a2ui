# Deliberate divergences from the reference implementations

Where this port intentionally differs from the Python/TypeScript reference, and why.
Conformance suites remain the source of truth; every entry here is either invisible to
them or documented as a skip with a reason.

## Schema validation

- **`format` is an annotation by default.** The Python SDK validates without a
  `FormatChecker`, so `format: "uri"` never fails there; the upstream spec test runner
  uses ajv with ajv-formats, which does assert it. `A2UICore.Schema.validate/3` takes
  `formats: :assert` for the latter; the spec-case replay uses it (one case,
  `openUrl: Invalid URL format (not a URI)`, depends on it).
- **`unevaluatedItems` raises.** No A2UI schema uses it; supporting it would need
  array-item annotation tracking that nothing exercises.
- **2020-12 meta-schema is bound to `true`** when validating v1.0 catalog documents
  (`catalog_definition.json` embeds schemas by `$ref` to it). Supporting the real
  meta-schema needs `$dynamicRef`, which the engine does not implement. Verdicts match
  ajv on all upstream cases because none of them carries a malformed embedded schema.
- **Leading `]` in a character class is a literal** (`[]a]`, `[^]a]`), as in the
  reference's PCRE-style `regex` module, not an empty / any-character class as in
  ECMA-262. No A2UI schema or catalog uses either form.

## Messages

- **`nil` payload decodes to `{:ok, []}`** (TypeScript behaviour). The Python factory
  rejects it.

## State

- **Writes are atomic on error.** Python's `DataModel.set` can leave a partial write
  behind when a later path segment fails. No conformance case reads state after an
  error step, so this is invisible to the suites; the Elixir port returns the original
  model on error.
- **Observers do not hold live references.** In Python an observer registered before
  `dispose/1` sees in-place mutations afterwards. An immutable model cannot reproduce
  that, and no case asserts it.
- **Deterministic iteration order.** Components, child properties and object keys are
  visited in sorted order (`Components.to_list/1`, `RefSpec.extract/2`,
  `Topology`), not JSON insertion order, because Elixir maps are unordered. When a
  graph has several violations the one reported is therefore stable but may differ
  from the reference's first-inserted choice. Conformance cases carry one violation
  each; only messages are asserted.
- **Child-reference property paths** put subscripts directly after the key
  (`children[0]`, `tabs[1].child`, `items[0][1]`); the reference joins nested lists
  with a dot in a few unexercised shapes.
- **`$ref` cycles are cut.** `Catalog.ReferenceMap` stops on a `$ref` it is already
  expanding; the Python analysis would recurse until it hits the interpreter limit.

## Catalogs

- **`protocolVersion` is not emitted by `Catalog.to_schema/1`.** The reference drops
  it from the consolidated document as well; the catalog struct carries the version.
- **Local `$ref`s are not inlined.** The Python catalog rewrites `#/$defs/…` pointers
  into copies of their targets before validating. Here the self-contained schema keeps
  the pointers and the schema engine resolves them at validation time, which accepts
  and rejects the same documents.
- **Union members are sorted.** Generated `anyComponent` / `anyFunction` lists and the
  `oneOf` / `anyOf` unions are ordered by name (maps carry no insertion order). The
  `catalog_schema` handler compares unions as sets of references.
- **`anyFunction` is synthesized when referenced but undefined.** A catalog that uses
  `FunctionCall` without declaring functions gets `"anyFunction": {"not": {}}`, so the
  bundle stays self-contained and no function call validates.
- **Catalogs are filtered by an authored `anyComponent` / `anyFunction`.** Only the
  names those unions list are kept. Python inlines local refs before applying the
  filter, which makes it dead code there; the intent (and the TypeScript behaviour) is
  to restrict the catalog.
- **`flatten: true`** is an extra `Catalog.from_json/2` option: it merges `allOf`
  component envelopes into one `properties` / `required` schema. The harness uses it
  for inline `catalog_schema` cases, whose expectations describe the flat shape.
- **`inf` / `nan` strings are not numbers.** Python's `float("inf")` succeeds; the BEAM
  has no non-finite floats, so `Coerce.to_float/1` rejects them and the numeric
  functions treat them as non-numeric.

## Functions and expressions

- **Locale data.** `A2UICore.Formatter.Default` formats every locale as `en-US` (the
  only one the suites exercise; Python falls back to it for unknown locales too).
  Hosts that need CLDR data plug in their own `A2UICore.Formatter` module.
- **Errors are values.** Where the reference raises while resolving a dynamic value
  (reserved keys, failing functions, unknown catalogs), `DataContext.resolve_dynamic_value/2`
  returns `nil` plus an `{:error, %{code: "EXPRESSION_ERROR", …}}` effect, so one bad
  binding cannot abort the resolution of its siblings. Missing bindings come back as
  `{:warning, %{code: "MISSING_DATA_BINDING", …}}`, once per path per call.
- **Template parsing counts characters.** The 10 000-character limit applies to
  codepoints, not bytes (as in Python, unlike JavaScript's UTF-16 length).

## Processor and validation

- **Envelopes are validated against a permissive catalog.** `Processor.process/2`
  decodes with `catalog: :permissive` (any component object, any theme, a
  well-formed function call), and the processor then checks every component against the
  catalog its surface actually uses. The reference binds the first catalog's schema into
  the envelope check, so a component of a second catalog could only be validated there
  by accident.
- **Calls into another catalog pass the schema stage.** A function call naming a
  `catalogId` other than the component's own is checked for well-formed identifiers
  only; the catalog's own `anyFunction` union would reject it.
- **`allowed_messages` is enforced.** `ValidationConfig.allowed_messages` is declared
  but never read in the Python SDK. The processor rejects other actions with
  `INVALID_ACTION`.
- **Failures are values, with no rollback across operations.** `Processor.process/2`
  returns `{:error, error, processor}`; operations applied before the failing one stay
  applied (as in the reference), and a failing `updateComponents` batch leaves its
  surface untouched.
- **Detail codes follow the conformance corpus for component properties.** A property
  that fails its schema is `missing_field` (required), `extra_field` (surplus) or
  `invalid_value` (everything else). Python's payload validator reports `type`, `enum`,
  `pattern` and `format` failures as `type_mismatch`; the shared suites (asserted by the
  Swift runner) expect `invalid_value`. An unknown component carries
  `unrecognized_component` as in Python plus `invalid_value` at its `component`
  property.
- **Detail paths are located by message.** Failures inside a message list or
  `{"messages": [...]}` wrapper carry `messages.<i>.` in front of the envelope path
  (`messages.0.createSurface.catalogId`), as the Swift SDK does; Python never asserts
  paths. Component-level details keep their `components.<id>.<property>` form, which
  the harness matches by tail (`chartType` is found at `components.c1.chartType`).
- **v0.8 suites are skipped by file name.** A suite ending in `_v0_8.yaml` is out of
  scope even when a case names no version.

## Node resolution and accessibility

- **The resolver is a value, not an observer.** The TypeScript and Dart resolvers are
  reactive: nodes hold signals and notify subscribers. `NodeResolver` is immutable. The
  host hands it the surface after a change (`update/2`) and reads what happened from the
  returned notifications (`{:node_created | :node_updated | :node_destroyed, ref}`).
  One `update/2` is one batch, so a node whose props changed reports once however many
  properties moved. The suite's "last emission equals final props" and "earlier binding
  snapshots stay unchanged" checks hold by construction and are not asserted.
- **Identity is the edge, not the object.** A node keeps its `ref` while the edge that
  leads to it (parent, property slot, component id, data path, occurrence) keeps leading
  to the same kind of node. A placeholder that receives its definition, or a component
  whose type changes, is a new node and the old one is destroyed — the behaviour
  `replaced_nodes` asserts.
- **Diagnostics are edge-triggered.** An unknown type, a cycle or a binding problem is
  reported when it appears and again only after it went away.
- **Literal dynamic properties are read-only bindings.** With `wrap: true` the Binder
  uses the schema's declared properties (including `allOf` envelope members), so a
  literal in a `DynamicString` slot arrives as `%Binding{value: …, path: nil}` like the
  reference's `ResolvedBinding`; without it the Binder keeps inferring from the value's
  shape.
- **Accessibility is checked at the model level only.** No upstream SDK runs
  `accessibility.yaml` (Python skips it, TypeScript has no handler, Swift checks a subset
  of literal attributes). The Elixir handler checks `label`, `description`, `live`,
  `hidden`, `role` and `checked` against `A2UICore.Accessibility`, asserts `{path: …}`
  expectations as bindings, and runs the catalog lint. `assertions.axeCore` names DOM
  rules of a browser renderer; it is ignored here and belongs to the Phoenix renderer's
  tests.
- **Roles and the lint heuristic are ours.** The spec fixes the attributes and the
  explicit-over-inferred rule, not role names or how a linter recognises "accepts
  actions or input bindings". The role map is the four types the suite names; the lint
  treats a property referencing `Action`, or a `value` bound to a `Dynamic*` type, as
  interactive and accepts any of `label`, `title`, `text`, `child` as a labelling
  fallback.

## Function RPC

- **There is no listener and no future.** The Python handler takes an
  `outbound_listener` callback and returns an asyncio future per agent call. `RPC` is a
  value: `call_agent_function/4` returns the `callAgentFunction` message and a pending
  record, and a call is settled by data the host feeds back (`agentFunctionResponse`,
  `timeout/2`, `cancel/3`, `dispose/2`), which returns `{:resolved | :rejected, …}`
  settlements. `NO_LISTENER` therefore never occurs; the timeout of a call is exposed
  (`pending_timeout/2`) for the host to arm a timer.
- **Call ids are counted.** A call without an explicit `functionCallId` gets `call-<n>`
  from a counter in the handler rather than a random UUID, so the handler stays
  deterministic.
- **Functions run synchronously.** An implementation is `(args, context) -> {:ok, value}
  | {:ok, value, effects} | {:error, error}`; there is no awaitable result to wait for.
  A raised exception becomes `EXECUTION_ERROR` as in Python.
- **An omitted `allowedCallers` means `rendererOnly`.** The protocol guide defines the
  default and Python's handler applies it; `A2UICore.Catalog.Function` keeps `nil` for
  "omitted" and the RPC reads it as `rendererOnly`.
- **The wire format requires a `catalogId`.** A `callRendererFunction` without
  `callFunction.catalogId` fails envelope validation, so the "no catalog id" resolution
  (the surface's default catalog) is reachable only through the `:catalog` option of
  `RPC.call_renderer_function/3`.
- **The first surface supplies the call context.** As in Python, `callRendererFunction`
  executes in the data context of the first surface unless `:surface_id` names one.

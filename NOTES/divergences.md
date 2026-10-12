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

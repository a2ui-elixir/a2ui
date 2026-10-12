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

## State (Phase 3)

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

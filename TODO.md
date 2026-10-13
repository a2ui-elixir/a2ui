# TODO — Elixir A2UI port

Working task list, ticked as work lands; one local commit per milestone.
Phases follow PLAN.md §11. Case counts exclude v0.8. Upstream reference
harness: `reference/a2ui/python/a2ui_core/tests/test_conformance.py`
(line numbers below refer to it).

## M2 — Finish Phase 2 (wire fidelity) — conformance target: 25 cases

- [x] M2.1 Baseline and VCS: `.gitignore` additions, crash dumps removed,
      `git init` + baseline commit, this file.
- [x] M2.2 Reference resolution for core tests (`test/support/reference.ex`,
      `A2UI_REFERENCE_ROOT` or walk up to `reference/a2ui`) + guard test
      (`A2UI_REQUIRE_REFERENCE=1`, generated counts > 0).
- [x] M2.3 First real run of the fidelity corpus: ajv spec cases (v1.0 +
      v0.9.1), 43 + 43 example bundles, both JSONL files. Register
      `catalog_definition.json` and the 2020-12 meta-schema (as `true`);
      unquote only names into tests; keyword-inventory test (structural
      walk); round-trip tests (`encode(decode(x))`, bundle-schema check).
- [x] M2.4 Ordering bug in `Adapter.extract_list/4` (`Enum.reverse(ops, acc)`)
      + order tests + `[msg, 42]` parity.
- [x] M2.5 Harness upgrades: YAML `{}` → map fix (`map_node_format`);
      `Handler` behaviour; domain-aware `Dispatcher` (core 2–7,
      extensions/a2a 9, agent + other extensions 10, express/legacy
      optional); `resolve_protocol_version` port; `Matchers` category
      hierarchy, exact/subset rules, parse-expression rules; `SkipPolicy`
      comment fix.
- [x] M2.6 Handlers `agent_to_renderer_schema`, `common_types_schema`,
      `validate_common_type` (`A2UICore.CommonTypes.validate/3`, root bound
      to `common_types.json`, exact `anyFunction` stubs). 25/25 green.
- [x] M2.7 Vendored-drift test (priv schemas/catalogs == reference).
- [x] M2.8 Hygiene and docs: duplicate `dialyzer:` key; root README with
      re-clone steps; PLAN.md fixes (license, counts, exit criteria); CI clones
      the reference; repair the coverage gate (`test_coverage` everywhere,
      `coveralls --umbrella`, drop `--max-failures=0`, 95% on core).
- [x] M2.9 Gate + commit "phase 2".

## M3 — Phase 3: State — target: `data_model` 51, `resolve_path` 15

- [x] M3.1 `A2UICore.State.DataModel` (port of `state/data_model.py`; pure;
      atomic on error — see `NOTES/divergences.md`).
- [x] M3.2 `State.Component` / `State.Components` (catalog-agnostic
      `children_fun`, Python `ComponentRefSpec` wording).
- [x] M3.3 Integrity/topology (root, dangling, self-ref, cycles, depth 50,
      orphans, composition constraints; Python + TS phrasings).
- [x] M3.4 `State.Surface`, `State.SurfaceGroup` (effects as data; clock
      injected).
- [x] M3.5 `Resolution.DataContext` path scoping.
- [x] M3.6 Handlers `data_model` (L1248–1344), `resolve_path` (L1231).
- [x] M3.7 Property tests (StreamData).
- [x] M3.8 Gate + commit "phase 3".

## M4 — Phase 4: Catalog, functions, expressions — target ≈185

- [x] M4.1 `A2UICore.Catalog` (`from_json`, indexes, name rules, schema
      rules, `to_schema`, component payload validation).
- [x] M4.2 `Catalog.ReferenceMap`.
- [x] M4.3 `A2UICore.Expression`.
- [x] M4.4 Functions behaviour + basic catalog functions + `@index`.
- [x] M4.5 `A2UICore.Formatter` (en-US default, pluggable).
- [x] M4.6 DataContext dynamic values.
- [x] M4.7 `CatalogFixtures` (L162–171, L221–473) + handlers `from_json`,
      `catalog_schema`, `evaluate_function`, `parse_expression_template`.
      291 passed, 0 failed; the 7 `test_v09_catalog_*` cases upstream skips
      also pass.
- [x] M4.8 Gate + commit "phase 4".

## M5 — Phase 5: Processor — target ≈184 (conformance: 476 passed, 595 skipped)

- [x] M5.1 `A2UICore.Processor` (`new/2`, `process/2`, `apply_operation/2`;
      atomic `updateComponents`; effects as data; `allowed_messages`).
- [x] M5.2 Batch validation: `Validation.ComponentsUpdate` (duplicate ids,
      per-component schema, prospective graph); `Payload` lets calls into
      another catalog through the schema stage.
- [x] M5.3 `Resolution.Binder` (schema-driven classification with a
      value-shape fallback; checks → `isValid` / `validationErrors` /
      `validationResult`). `ComponentContext` is not needed: the harness
      resolves templates in `A2UIConformance.SurfaceState`.
- [x] M5.4 `Processor.renderer_capabilities/2`, `renderer_data_model/2`,
      `select_catalog`, `dispatch_action` handlers.
- [x] M5.5 `messages.<i>.` detail paths (list and wrapper payloads, the
      registry's version checks, the `surfaceId` pre-check) and the
      harness' `details` matcher (Swift rule, dotted paths).
- [x] M5.6 Handlers `validate`, `process_messages`, capabilities, data model,
      `select_catalog`, `dispatch_action`; `PyStr` (Python `str`/`repr`) and
      `SurfaceState` for the shared surface assertions.
- [x] M5.7 Gate + commit "phase 5".

## M6 — Phase 6: Node resolution, accessibility — target 14 (conformance: 517 passed, 581 skipped)

- [x] M6.1 `Resolution.NodeResolver` / `Node` / `Binding` / `Action`: a pure,
      diff-based port of the TS node resolver (identity by edge, `:pending`,
      `:unknown_type` and `:cyclic` placeholders, per-item template scopes,
      edge-triggered diagnostics, `write/4`, `invoke/5`, `dispose/1`).
      `Binder` gained `wrap: true`.
- [x] M6.2 `A2UICore.Accessibility`: `label`/`description`/`live`/`hidden`
      with explicit-over-inferred precedence, basic-catalog roles and
      `checked`, and the catalog `lint/1` the spec asks SDK tooling for.
- [x] M6.3 Handlers `resolve_nodes` (port of `node-resolution.ts`) and
      `accessibility_check` (model-level; `axeCore` DOM rules ignored).
- [x] M6.4 Gate + commit "phase 6".

## M7 — Phase 7: RPC v1.0 — target 15 (conformance: 532 passed, 566 skipped)

- [x] M7.1 `A2UICore.RPC`: pure state machine (renderer-function calls with
      catalog/version/caller/activation/argument checks and safe execution;
      pending agent calls settled by response, timeout, cancel or dispose).
- [x] M7.2 `Processor` integration (`{:rpc_response, …}` and
      `{:rpc_settled, …}` effects, `call_agent_function/4`, timeout, cancel,
      dispose) and `Message.RendererToAgent` builders (`action`, `error`,
      `callAgentFunction`, `rendererFunctionResponse`).
- [x] M7.3 Handler `handle_rpc` (15 cases; the 3 A2A cases stay with M9).
- [x] M7.4 Gate + commit "phase 7", then checkpoint and re-plan M8–M11.

## Checkpoint after Phase 7

Core engine complete: 487 of 487 runnable `core/` cases pass (37 v0.8 cases are
skipped by policy). Conformance: 532 passed, 566 skipped, 0 failed. Core: 1365
tests. Coverage 95.9%. Format, compile, credo and dialyzer are clean.

Remaining cases by suite family:

| Family | Cases | Handled by |
|---|---|---|
| `agent/` shared (catalog provider/resolution/transformer, multi-catalog formats, request processor, skill) | 94 | M10 |
| `agent/direct_json` (compiler, decompiler, prompt, response parser, streaming) | 162 | M10 |
| `agent/express` | 115 | optional |
| `agent/legacy` | 94 (+39 v0.8) | optional |
| `extensions/a2a` | 14 | M9 (see decision D2) |
| `extensions/adk` | 11 | out of scope (see decision D3) |

## M8–M11 — proposed at the Phase 7 checkpoint (awaiting approval)

### M8 — `a2ui_phoenix` renderer

- [ ] M8.1 `A2UIPhoenix.Session`: a value wrapping `Processor` and one
      `NodeResolver` per surface (`handle_message/2`, `write/4`, `invoke/4`),
      returning the render state and the outbound messages.
- [ ] M8.2 Function components for the 18 basic components, v0.9.1 and v1.0,
      with ARIA from `A2UICore.Accessibility`; a component-map behaviour so a
      custom catalog can bring its own.
- [ ] M8.3 `A2UIPhoenix.Surface` LiveComponent: recursive node rendering,
      placeholders, templates.
- [ ] M8.4 Interaction: input events → `write`, buttons → `invoke` → outbound
      `action`; `isValid`/`validationResult` display; `openUrl` hook.
- [ ] M8.5 LiveViewTest: render all 43 + 43 example bundles, a contact-form
      flow, a11y attributes present.
- [ ] M8.6 Gate + commit.

### M10 — `a2ui_agent` (blueprint direct_json)

- [ ] M10.1 Catalog provider, resolution and transformer (48 cases).
- [ ] M10.2 direct_json compiler, decompiler and prompt generator (27).
- [ ] M10.3 Response parser `wrap`/`unwrap`/`parse_response` and
      multi-catalog formats (36).
- [ ] M10.4 Request processor and skill (27).
- [ ] M10.5 Streaming parser (118 `parse_chunk` cases): an incremental
      scanner as a pure state machine, with the cut-surrogate healing rules.
- [ ] M10.6 Examples round-trip test + gate + commit.

### M9 — transports

- [ ] M9.1 SSE plug and transport contract tests.
- [ ] M9.2 A2A helpers (part creation/detection, extension negotiation,
      `message/send` handler with `<a2ui-json>` extraction).
- [ ] M9.3 Explicit skip entries for the ADK-specific cases.

### M11 — release

- [ ] M11.1 ExDoc guides (core, Phoenix, agent), READMEs, changelog.
- [ ] M11.2 Hex metadata and `mix hex.build` dry-run for the three packages.
- [ ] M11.3 CI on the pinned reference; `SPEC_PIN` bump procedure.

### Decisions

- **D1 Order.** PLAN.md says 8 → 9 → 10 → 11. Recommended: 8 → 10 → 9 → 11.
  The renderer exercises the node-resolver API while it is cheap to change;
  the agent SDK is the largest conformance-gated block; transports need both.
- **D2 A2A cases.** The cases are written against the v0.8 extension URI and
  `beginRendering`. Invariant 3 excludes v0.8. Options: implement the
  version-agnostic helpers with v0.9.1/v1.0 URIs and skip the v0.8-specific
  cases, or skip the family.
- **D3 ADK cases.** `convert_event` and `execute_tool` are specific to
  Google's Python ADK. Recommended: skip with a stated reason.
- **D4 Package placement.** The pure A2A helpers have no Phoenix dependency;
  recommended in `a2ui_agent` rather than `a2ui_phoenix`.

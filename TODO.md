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

- [ ] M4.1 `A2UICore.Catalog` (`from_json`, indexes, name rules, schema
      rules, `to_schema`, component payload validation).
- [ ] M4.2 `Catalog.ReferenceMap`.
- [ ] M4.3 `A2UICore.Expression`.
- [ ] M4.4 Functions behaviour + basic catalog functions + `@index`.
- [ ] M4.5 `A2UICore.Formatter` (en-US default, pluggable).
- [ ] M4.6 DataContext dynamic values.
- [ ] M4.7 `CatalogFixtures` (L162–171, L221–473) + handlers `from_json`,
      `catalog_schema`, `evaluate_function`, `parse_expression_template`.
- [ ] M4.8 Gate + commit "phase 4".

## M5 — Phase 5: Processor — target ≈184

- [ ] M5.1 `A2UICore.Processor`.
- [ ] M5.2 `Validation.Payload` (messages, function args, allowedCallers,
      reserved keys).
- [ ] M5.3 `Resolution.Binder` + `ComponentContext` (generic_binder port).
- [ ] M5.4 Capabilities, renderer data model, `select_catalog`,
      `dispatch_action`.
- [ ] M5.5 `messages.<i>.` detail paths.
- [ ] M5.6 Handlers `validate`, `process_messages`, capabilities, data model,
      `select_catalog`, `dispatch_action`.
- [ ] M5.7 Gate + commit "phase 5".

## M6 — Phase 6: Node resolution, accessibility — target 14

- [ ] M6.1 `Resolution.Node` (TS port).
- [ ] M6.2 Accessibility checks.
- [ ] M6.3 Handlers `resolve_nodes`, `accessibility_check`.
- [ ] M6.4 Gate + commit "phase 6".

## M7 — Phase 7: RPC v1.0 — target 15

- [ ] M7.1 `A2UICore.RPC` state machine.
- [ ] M7.2 Processor integration + outbound encoders.
- [ ] M7.3 Handler `handle_rpc`.
- [ ] M7.4 Gate + commit "phase 7", then checkpoint and re-plan M8–M11.

## M8–M11 (planned at the Phase 7 checkpoint)

- M8 Phoenix renderer · M9 Transports (SSE, A2A) · M10 Agent SDK (blueprint
  direct_json first; Express and legacy optional) · M11 Release.

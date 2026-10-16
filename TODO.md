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

## M8–M11 — approved 2026-10-14 (order 8 → 10 → 9 → 11; D1–D4 as recommended)

### M8 — `a2ui_phoenix` renderer (phoenix: 155 tests; conformance unchanged)

- [x] M8.1 `A2UIPhoenix.Session`: the processor plus one `NodeResolver` per
      surface (`handle_message/3`, `write/5`, `invoke/4`, `dispose/1`), effects
      as data (`{:send, message}`, `{:open_url, url}`, diagnostics); core
      gained `Processor.set_data/4` for renderer-side writes.
- [x] M8.2 Function components for the 18 basic components (v0.9.1 and
      v1.0) with ARIA from `A2UICore.Accessibility`; a component map
      (`%{type => component}`) merged over `Components.Basic.components/0`.
- [x] M8.3 `A2UIPhoenix.Surface` LiveComponent: recursive node rendering,
      placeholders, templates; local UI state (tabs, modals, filters).
- [x] M8.4 Interaction: form changes → `Inputs.decode/4` → `write`; buttons,
      chips → `invoke`/`write`; check messages and `aria-describedby`;
      `openUrl` pushed to the browser (`priv/static/a2ui_phoenix.js`);
      `A2UIPhoenix.Live` hosts the session in a LiveView.
- [x] M8.5 LiveViewTest: all 43 + 43 example bundles render, the contact-form
      flow, tabs, the modal sample, inputs, a11y attributes.
- [x] M8.6 Gate + commit.

### M10 — `a2ui_agent` (blueprint direct_json) (agent: 285 tests; conformance: 724 passed, 376 skipped)

- [x] M10.1 Catalog provider, resolution and transformer: 48 of 48
      (`CatalogProvider`, `CatalogConfig`, `CatalogTransformer`,
      `CatalogResolver`).
- [x] M10.2 direct_json compiler, decompiler and prompt generator: 27 of 27
      (`DirectJson.Prompt`, `SchemaPruning`, `PayloadValidator`; compile is
      clean + lenient read + `validate_payload`, as upstream has no compiler
      module).
- [x] M10.3 Response parser `wrap`/`unwrap`/`parse_response` (17 of 17) and
      multi-catalog formats (3 of 19; the other 16 use Express).
- [x] M10.4 Request processor (16 of 23; 7 use Express) and skill (0 of 4,
      all Express). `Format` behaviour, `RequestProcessor`, `Generator`.
- [x] M10.5 Streaming parser: 79 of 118 `parse_chunk` cases (39 use v0.8
      catalogs). `JsonReader` heals cut strings and surrogate pairs;
      messages already emitted are not validated again.
- [x] M10.6 Examples round trip: each of the 86 basic-catalog bundles is
      decompiled into a response and read back whole and streamed.
      `31_incremental-dashboard` (both versions) is not one valid payload
      (unreachable placeholders; non-UAX #31 ids in v1.0) and is asserted to
      fail, as Python's `validate_payload` does. Gate + commit.

Not covered: Express-format cases (`agent/express` 115, plus 27 in the shared
suites above), `agent/legacy` (94 + 39 v0.8), and the fluent builder and
macros suites (`agent/builder` 11, `agent/macros` 18; a separate golden-file
format the harness does not load).

### M9 — transports (agent: 345 tests; phoenix: 167 tests; conformance: 737 passed, 363 skipped)

- [x] M9.1 `A2UIPhoenix.Plug.SSE`: one event per message (`data:` lines and an
      optional `event:` type), read lazily, stopped when the client goes.
      Contract tests: framing and order over all 86 example bundles, a client
      that leaves, and a smoke test over a real connection (Bandit, read off
      the socket).
- [x] M9.2 A2A: `A2UIAgent.A2A` (extension URIs, agent-card entry,
      negotiation, parts); `A2UIAgent.A2A.Server` (`message/send` answers with
      the task; `message/stream` with the task, `working` updates and a final
      update; capabilities and data model from the metadata, renderer
      messages from data parts, a generator per protocol version);
      `A2UIAgent.A2A.Plug` (optional `plug`: JSON-RPC over HTTP, SSE for
      streams, `X-A2A-Extensions`, the agent card on `GET`) with a smoke test
      over Bandit. `extensions/a2a`: 13 of 14; `test_handler_replaces_smart_quotes`
      is a v0.8 payload and is skipped.
- [x] M9.3 `extensions/adk` (11) skipped as an optional family: adapters to
      Google's Python Agent Development Kit.
- [x] M9.4 Gate + commit.

PLAN's interop test against an upstream sample agent would need that sample's
npm packages and a model. Instead the server follows the Node sample agent's
own server tests: `message/send` returns the task; `message/stream` sends the
`submitted` task, `working` updates and a final `input-required` update; a
failed negotiation fails the task already announced.

### M11 — release (docs build without warnings; `hex.build` for the three packages; nothing published)

- [x] M11.1 Guides: `processing_messages` (core), `rendering_surfaces`
      (Phoenix) and `serving_an_agent` (agent). Every example runs as
      written: the code blocks were run as scripts, and the LiveView, custom
      component, SSE and A2A examples inside an app made by `mix phx.new`.
      READMEs rewritten, a CHANGELOG per package, ExDoc config per package
      (module groups, the guide, source links into `umbrella/apps/<app>`,
      `a2ui_core` links to hexdocs). `mix docs --warnings-as-errors` is clean;
      the operation structs `Message.decode/2` returns are now documented.
- [x] M11.2 Hex metadata: `files`, links, descriptions. `a2ui_core` ships
      the specification's schemas and catalogs in `priv/` with their license
      file (`priv/LICENSE-APACHE`). `a2ui_phoenix` and `a2ui_agent` use
      the sibling app inside the repository and `a2ui_core ~> 0.1.0` in the
      package (`A2UI_HEX_BUILD=1` for a build; without it `hex.build` drops
      the dependency). The three tarballs, unpacked into a fresh project,
      compile and pass the guides' examples.
- [x] M11.3 CI `package` job: the docs with warnings as errors and the three
      `hex.build`s. README: conformance scoreboard, releasing, `SPEC_PIN` bump
      procedure. The drift test also fails when upstream adds or removes a
      schema file. `a2ui_conformance` depends on `plug` in dev and test, so
      `a2ui_agent` compiles the same when that app is built on its own. The
      SSE and A2A smoke tests read the response straight off the socket:
      `:httpc` keeps body data that arrives together with the headers until
      more data comes, so a test waiting on its first event failed now and
      then (OTP's `httpc_handler`).

Open before a first release: the repository URL (`@source_url` names
`github.com/a2ui-project/a2ui-elixir`, the upstream organization's namespace);
the copyright holder in the LICENSE files ("lab-elixir-a2ui contributors");
a license review of upstream text reproduced verbatim because the suites
compare it exactly (the direct JSON prompt rules, error messages).

### M12 — spec bump to `5d74ffb` (2026-10-16; conformance: 788 passed, 374 skipped; 741 of 1115 upstream cases run)

56 upstream commits since `ce03d00`. Everything the new suites run passes;
the skips are the same families as before (Express, legacy, v0.8, ADK).

- [x] M12.1 Vendored schemas copied: `callRendererFunction.surfaceId`,
      `IndexSystemFunction` without `returnType`, the coercion descriptions
      of `DynamicBoolean` and `CheckRule` (both already implemented in the
      basic functions and the binder), key order.
- [x] M12.2 Catalog model, after the reference's catalog rewrite:
      `Catalog.to_json/2` writes the document back (in its key order with
      `ordered: true`), `validation_schema/1` (components flattened, common
      types bundled), peer catalogs for cross-catalog `$ref`s
      (`with_peer_catalogs/2`, `link_catalogs/2`), resolved entry schemas,
      `copy_with/2` for transformers; `@` names rejected in catalog documents
      from v1.0. New: `Catalog.Document`, `Catalog.Refs`,
      `Catalog.SchemaCleaner`, `Catalog.ValidationSchema`, `KeyOrder`.
- [x] M12.3 v1.0 catalog resolution: components and function calls run in
      the catalog they name or the surface's default; a v1.0 surface may have
      none; the calls nested in a batch are checked before it commits
      (`Validation.NestedCalls`); system calls skip catalog resolution.
- [x] M12.4 RPC: `surfaceId` picks the evaluation context (a context of its
      own with an empty data model without one, an error for an unknown
      surface); arguments are resolved, then validated; a call must name its
      catalog. Capabilities: v1.0 inline catalogs are `to_json` documents,
      earlier ones are built from the resolved schemas.
- [x] M12.5 Agent: the golden prompts (`expect_file`) are compared byte for
      byte and match; pruning goes through `copy_with/2`; catalog files and
      example files keep their key order; the v1.0 streaming parser fails on
      the chunk that closes a component that cannot validate.
- [x] M12.6 Harness: `validation_schema`, `round_trip` and `to_json`
      actions (upstream dropped `catalog_schema`), `evaluate_function` on a
      surface, peer catalogs for catalog cases.
- [x] M12.7 Unit tests for the new modules; README scoreboard, divergences
      (key order from ordered input, peers identified by value), guides and
      changelogs updated.

### M13 — Express inference format (2026-10-16; conformance: 940 passed, 223 skipped; 892 of 1115 upstream cases run)

All 151 Express cases pass: the `agent/express` suites (115), the Express cases of
`multi_catalog_formats` (24) and `request_processor` (8), and `skill.yaml` (4). The
skipped cases are the legacy agent SDK (94), protocol v0.8 (118) and ADK (11).

- [x] M13.1 `Express.Syntax`: a hand-written lexer and recursive-descent
      parser for `Express.g4` (strings with escapes, raw and triple-quoted
      strings, paths, checks, keyword arguments, maps, `_`), with the
      reference's error lines and columns. `A2UIAgent.BlockLexer` finds tagged
      blocks without closing them on a tag inside a string or comment.
- [x] M13.2 `Express.Compiler` (ported from TypeScript): surfaces,
      `createSurface`/`updateComponents`/`updateDataModel`/`deleteSurface`,
      `callRendererFunction`, positional and keyword arguments, inline
      component ids, templates, checks with the implicit bound value, events
      and function-call actions, static properties, several catalogs
      (`catalogId=`, ambiguity errors). Errors are `:parse` or `:validation`
      with the reference's help texts.
- [x] M13.3 `Express.SchemaHelper` (TypeScript semantics over the document
      Python reads) and `Express.Decompiler` (Python), including the TypeScript
      fix for map values written at a non-root path.
- [x] M13.4 `Express.Prompt` (Python): the rules, signatures, catalog
      instructions and examples; the golden prompt files match byte for byte.
      `A2UIAgent.Express` implements `A2UIAgent.Format`, so a generator or a
      request writes Express with `format: A2UIAgent.Express`.
- [x] M13.5 Skills: `A2UIAgent.Skill` (PyYAML-compatible frontmatter) and
      `A2UIAgent.SkillGenerator` (monolithic skill, core skill, catalog skills,
      skill sets); the golden skills match byte for byte.
- [x] M13.6 Core: `Catalog.Refs` and `Catalog.inline_refs/4` keep the key
      order of ordered documents (`ordered: true`).
- [x] M13.7 A2A: a parser without `parse_chunk/3` is buffered, and the
      response is parsed when the output is complete.
- [x] M13.8 Harness: format-aware agent handlers (format overrides, Express
      decompile on ordered fixtures), the skill actions, ordered YAML loading;
      `agent/express` is no longer an optional family.
- [x] M13.9 Guide section and module groups for Express and skills;
      divergences (prompt and decompiler from Python, compiler from TypeScript,
      key order, inline ids, error recovery, buffered A2A answers).

### M14 — builder and macros (2026-10-16; conformance: 969 passed, 223 skipped; 921 of 1144 upstream cases run)

The two golden suites now load: `agent/builder` (11) and `agent/macros` (18) pass,
golden output and golden validity both.

- [x] M14.1 `A2UIAgent.Builder`: component nodes, refs, bindings, child lists,
      function calls, actions, check rules and accessibility attributes;
      `flatten/2` with the reference's two-pass id allocation (author ids
      reserved bare and prefixed, `<root>__<name>_<n>` for the rest, lists of
      roots); with a catalog, defaults, catalog property order and component
      validation; `messages/2`. `A2UIAgent.Builder.Basic`: a function per basic
      component.
- [x] M14.2 `A2UIAgent.Macro`: declared parameters, the reference's schema
      mapping and argument coercion (ids to refs, bindings, action shorthands),
      call nodes for composition with a depth limit.
- [x] M14.3 `A2UIAgent.MacroExpander`: inference catalog (passthrough
      components, union refs, collisions), standalone macro catalog,
      `to_transport/2` (nested expansion, failures kept and logged, recursion
      errors), `to_inference/2`.
- [x] M14.4 Harness: golden suites loaded as cases (`build`, `expand` and the
      macro catalog actions), golden validity checked with a processor and the
      case's relaxations; the suite's macros written with the builder.
- [x] M14.5 Core: `KeyOrder.put/3` and `delete/2` also take maps.
- [x] M14.6 Guide section, module groups, divergences.

### M15 — legacy agent suites (2026-10-16; conformance: 995 passed, 198 skipped; 946 of 1144 upstream cases run)

- [x] M15.1 The legacy cases whose rules hold run against the blueprint
      interface (25): `parse_full` (unwrap and `PayloadFixer`, or the Express
      parser), `fix_payload`, `has_parts`, `select_catalog`, `load_catalog`.
- [x] M15.2 `A2UIAgent.PayloadFixer`: the reference's `parse_and_fix` (curly
      quotes, control characters in strings, trailing commas, wrapping, the
      unescaped-backslash hint with Python's line, column and offset).
- [x] M15.3 Superseded cases (67) skipped with the suite or rule that replaced
      them, validated against the corpus; legacy cases in the Elemental and Atom
      formats are optional like the shared ones.

### M16 — transports (2026-10-16; conformance unchanged: no suite covers them)

- [x] M16.1 SSE resumption: `{id, message}` events with `id:` lines, the
      `:retry` option, `last_event_id/1`; the test reader follows the WHATWG
      rules for `id` (it carries over to later events).
- [x] M16.2 `A2UIAgent.MCP`: resources, resource contents, tools with
      `_meta.ui`, tool results with embedded A2UI resources (text fallback,
      audience), reading messages back, renderer capabilities from
      `initialize` or a call's `_meta`, the `a2ui_action` and `a2ui_error`
      tools.
- [x] M16.3 `A2UIAgent.AGUI`: activity snapshots per surface (all messages so
      far, `deleteSurface` starts over), reading them back, user actions from
      `forwardedProps`, text and run events, SSE encoding.
- [x] M16.4 Guides (agent: MCP and AG-UI; Phoenix: resuming a stream),
      divergences (no WebSocket binding, MCP catalog not implemented).

### M17 — schema engine completion (2026-10-16; conformance unchanged; JSON Schema Test Suite draft 2020-12: 1302 of 1302 required tests)

- [x] M17.1 References: base URIs from `$id`, embedded resources, `$anchor`
      and `$dynamicAnchor` names, percent-encoded pointers, `$dynamicRef`
      over the dynamic scope; `$ref` is an applicator whose annotations
      reach `unevaluated*`.
- [x] M17.2 Keywords: `unevaluatedItems`, `dependentRequired`,
      `dependentSchemas`, `minContains`/`maxContains`, decimal limits,
      `multipleOf` without float overflow, `$vocabulary` of custom
      meta-schemas.
- [x] M17.3 ECMA-262 regular expressions: Unicode property names,
      ASCII `\d`/`\w`/`\b`, ECMA `\s` and `.`, `\u` escapes; XID
      properties exact on PCRE2 (Erlang/OTP 28+), which also makes
      `A2UICore.Identifier` agree with Python's `isidentifier()`.
- [x] M17.4 The spec-case replay validates catalogs against the real 2020-12
      meta-schemas (vendored as test fixtures with their BSD-3-Clause
      license) instead of `true`.

Not taken: the retry loop (no blueprint, suite or spec defines one; the guide
says to feed errors back to the model) and a CLDR-backed formatter (a
dependency decision; `A2UICore.Formatter` is pluggable).

### M18 — MCP catalog (2026-10-16; conformance unchanged: no suite covers it; JMESPath compliance suite: 892 of 892)

- [x] M18.1 `A2UICore.JMESPath`: lexer, Pratt parser, interpreter and every
      built-in function of the specification.
- [x] M18.2 The vendored MCP catalogs (v0.9, v1.0; drift-tested),
      `A2UICore.Catalog.MCP`, `A2UICore.Functions.MCP` (`callMcpTool` over the
      host's `A2UICore.MCP.Client`, `jmespath`, `split`, `regexCapture`,
      `regexReplace`, `updateDataModel`), `A2UICore.MCP` (A2UI in tool results
      and resources, MCP Apps); function effects `{:write, …}` and
      `{:messages, …}` reach the renderer from actions.
- [x] M18.3 `A2UIPhoenix`: the session applies those effects; `McpApp`
      (`A2UIPhoenix.Components.MCP`), the `A2UIMcpApp` hook and the sandbox
      proxy page; `A2UIPhoenix.Session.mcp_app_request/5` (tools, functions,
      data changes, model context, messages) with payload checks; Node tests
      for the browser code (CI runs them).

### M19 — examples (2026-10-16; conformance unchanged)

- [x] M19.1 `examples/restaurant_agent`: an agent over A2A (send and stream,
      direct JSON and Express), MCP, AG-UI, server-sent events and WebSocket,
      with a shared restaurant catalog (`Rating`, `checkAvailability`,
      `clientInfo`); a full booking tested through a real renderer session.
- [x] M19.2 `examples/terminal_client`: a renderer on `a2ui_core` alone that
      draws surfaces as text, with a client for each transport (`mix chat`).
- [x] M19.3 `examples/gallery`: ten scenarios (components, forms, data,
      surfaces, functions and RPC, custom catalogs, streaming, MCP, errors,
      v0.9), the 43 reference examples, a chat with the agent over A2A, and
      LiveDashboard metrics; LiveViewTest for every page, the chat against a
      live agent. Checked in a real browser.
- [x] M19.4 What running them found, fixed in the packages: agent function
      routing (v1.0) in the core and the Phoenix session; renderer-side
      `allowedCallers`/`requiresUserActivation`; `@index` in `formatString`
      templates; `formatDate` timestamps without seconds and TR35 quoting;
      decompiled direct JSON in protocol key order so it streams; the v0.9
      theme, `DateTimeInput` date default and stylesheet fixes in the
      renderer; error reports that point at the failing field; the
      `UNSUPPORTED_VERSION` code; `Builder.call/3` `:catalog_id`; Express data
      assignments as in Python and `decompile/3`'s `:surface_catalogs`.

### M20 — landing page (2026-10-16)

- [x] M20.1 `site/`: a Phoenix application with the landing page, light and
      dark: the hero's message streamed into a rendered surface whose data
      model and action are live; protocols and figures; architecture with
      each package's modules; a turn's lifecycle; the features by area with
      the message matrix, bindings, node tree, function calls, streaming
      parser and error report; the catalog as wireframes; transports and
      inference formats; code samples; examples and gallery scenarios; the
      conformance report and the gates.
- [x] M20.2 `mix site.build`: the page as static files with relative links
      (checked from disk and under a sub-path); Geist fonts bundled.
- [x] M20.3 Tests: the content against the repository (catalogs, schemas,
      README table, `SPEC_PIN`, modules, guides, examples), the rendered page
      (every feature, anchor and asset), the highlighter, the export; CI job
      `site`, whose export is kept as an artifact. Checked in a browser at
      phone, tablet and desktop widths, both themes, reduced motion.

### M21 — replays of the examples on the landing page (2026-10-16)

- [x] M21.1 `mix gallery.replays` (`examples/gallery/test/support/replays`):
      runs the restaurant agent's booking conversation over A2A in process,
      and the gallery's streaming and forms scenarios, against an
      `A2UIPhoenix.Session`; after each step it renders every surface with
      `A2UIPhoenix.Surface` and keeps the messages that crossed. Writes
      `site/priv/replays.json` and copies `a2ui_phoenix.css` into the site.
- [x] M21.2 The Examples section plays them: tabs per replay, the
      conversation with the surfaces as the renderer drew them, the messages
      with their JSON, the model's output for the streamed answer, a caption
      per step, and the user's moves acted out (typing, clicks, the agent at
      work). The first step is rendered on the server; the page reads
      without the script.
- [x] M21.3 Tests: the gallery checks that the site holds a fresh recording
      and that every move's target is on its step's surfaces; the site
      checks the player, the embedded data, the copied stylesheet and the
      icons. The restaurant agent takes its first booking day from
      `config :restaurant_agent, today:` (the tests' dates no longer depend
      on the day they run).

### M22 — design system for the renderer and the examples (2026-10-16)

- [x] M22.1 `a2ui_phoenix.css` rebuilt as a design system: tokens with the
      reference renderers' names (colors, type scale, space, radii, shadows,
      motion, per-component tokens), light and dark through `light-dark()`
      and the page's `color-scheme` (or the `a2ui-light`/`a2ui-dark`
      classes), colors derived from the primary color on each surface
      (hover, tint, text, focus ring, the text on it), and every basic and
      MCP component in one style.
- [x] M22.2 The components' markup: namespaced classes for every element and
      variant, states as ARIA attributes, one anatomy for the inputs (label,
      control, the messages of failed checks, read as guidance while the
      field is empty: `data-a2ui-empty`), Material Symbols icons, and a
      slider whose track fills to its value (rendered, and kept in step by
      the script).
- [x] M22.3 The gallery rebuilt on one UI kit (`GalleryWeb.CoreComponents`,
      `gallery.css`) drawn with the same tokens: page headers, panels, cards,
      buttons, badges, tags, tabs, surface frames, the message log, chat
      bubbles, callouts; Geist fonts, a theme switch, an icon-only header on
      phones, a favicon; the custom catalogs' components in `catalog.css`.
- [x] M22.4 The landing page's replays recorded again: the site sets the
      renderer's tokens from its theme and styles no component, and
      `mix gallery.replays` copies `catalog.css` too.
- [x] M22.5 The guide's styling and themes section (tokens, light and dark,
      markup), README, CHANGELOG; tests for the new markup; checked in a
      browser at desktop and phone widths in both themes: every scenario,
      the reference examples, the chat with the restaurant agent, and the
      replays.

### M23 — example surfaces (2026-10-16)

- [x] M23.1 The surfaces the example agents send, composed on a few shared
      patterns (header, section label, record, tiles, actions, status line;
      `examples/README.md`): the restaurant list as a horizontal list of
      tiles, the booking form in sections under a header with the
      restaurant's picture, the confirmation as a summary card, and the ten
      gallery scenarios.
- [x] M23.2 Pictures drawn for the examples: each restaurant's dish in SVG
      (`RestaurantAgent.Pictures`, served at `/images/:id.svg`), the
      gallery's landscape, avatar and poster, and its clip.
- [x] M23.3 Renderer layout rules: cards in a horizontal list as tiles of
      one width (`--a2ui-list-card-width`), a card filled by its layout
      child, a caption under a heading drawn as its subtitle, busy text with
      its indicator on its line; the MCP App gets the component's color
      scheme as its host theme and is told when it changes. The gallery's
      trip dashboard follows it.
- [x] M23.4 The terminal client prints a horizontal list of one-line items
      on one line; the replays recorded again; the site's icon subset holds
      the icons they use; READMEs, the guide, CHANGELOG; checked in a browser
      at desktop and phone widths in both themes.

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

# Elixir/Phoenix A2UI — Implementation Plan

A plan for a spec-faithful, multi-version, Loupe-quality Elixir implementation of the
[A2UI protocol](https://a2ui.org) (Apache-2.0, Google + CopilotKit), shipped as a small
family of focused Hex packages with Phoenix/LiveView as the reference renderer.

> Companion documents: `NOTES/research.md` (protocol findings, deltas, constraints,
> ecosystem findings) and `reference/` (upstream repos, cloned read-only).

---

## 1. North Star

> "A Phoenix app should be able to render an agent-driven UI and, with a catalogue it
> controls, send structured UI intents to an agent — with the full confidence of the
> upstream conformance suites."

Three packages:

| Hex package | App | Layer | Purpose |
|---|---|---|---|
| `a2ui_core` | `:a2ui_core` | Protocol engine | messages, schemas, state, catalog, functions. **Zero runtime deps beyond Jason.** No Phoenix. |
| `a2ui_phoenix` | `:a2ui_phoenix` | Renderer adapter | LiveView components + transports. Depends on `a2ui_core`. |
| `a2ui_agent` | `:a2ui_agent` | Agent SDK | prompt generation, LLM-response parsing, builder DSL. Depends on `a2ui_core`. |

Enables both directions: Phoenix-as-renderer (agent → LiveView) and
Elixir-as-agent (Elixir backend → any A2UI client).

## 2. Position vs the existing `a2ui` Hex package

The name is taken: `actioncard/a2ui-elixir` 0.3.0. Good prior art (v0.9 messages, 18
LiveView components, Local/SSE/JSON-RPC/A2A transports, `use A2UI.Live`/`A2UI.Agent`
macros) — but: v0.9-only (v0.9.1/v1.0 unknown), no conformance harness, monolithic
(core+renderer+transports in one package), no JSON-Schema catalog validation, no RPC,
no composition constraints, no expression template parsing, and **it claims the
module namespace `A2UI.*`**.

Consequences:

1. We cannot ship a package whose root module is `A2UI` — an app depending on both
   would break. Our packages use `A2UICore`, `A2UIPhoenix`, `A2UIAgent` as the public
   namespaces. So the Hex names and module roots agree:
   `a2ui_core → A2UICore`, `a2ui_phoenix → A2UIPhoenix`, `a2ui_agent → A2UIAgent`.
2. We will still respect upstream naming inside modules (e.g.
   `A2UICore.DataModel`), keeping a mechanical correspondence with SDK taxonomy.
3. Positioning: ours is the **spec-faithful, multi-version, conformance-certified,
   layered** implementation; theirs is a fast-moving v0.9 renderer. Both can coexist
   in the ecosystem. We do not fork it and we do not copy code (different license
   review is out of scope; we build from the spec).

## 3. Target versions

| Version | Status upstream | Our stance |
|---|---|---|
| v0.9 / v0.9.1 | Current production | **Support** |
| v1.0 | Release candidate | **Support** (feature flag recommended in host apps) |
| v0.8 | Legacy | Out of scope; adapter seam kept small and documented |

`SPEC_PIN` file at repo root records the upstream commit of `r
eference/a2ui` against which conformance suites were last run.

## 4. Design principles

### 4.1 Elixir/BEAM first

1. **Data, then pure functions.** `Processor`, `DataModel`, `SurfaceComponentsModel`,
   `Node` are plain data + pure functions. No processes inside `a2ui_core`.
2. **Processes exist only at the boundary.** Hosts process mailboxes (LiveView,
   GenServer agent) already provide ordering. RPC correlation belongs to the caller's
   process (e.g., a `send_after` timer in the LiveView).
3. **GenServer per caller, not per entity.** A `SurfaceGroupModel` is **passed by
   value** in socket assigns/state, not a GenServer. We add zero global servers.
4. **One-way module dependency.** e.g. `Processor → State → Resolution → Schema`.
   No cycles. `mix xref graph --format dot` is part of CI.
5. **Reactive updates come free.** LiveView's assigns tracking replaces the reference
   implementation's signal layer; we **do not port** `signal/computed/effect`. The
   resolution step emits a plain nested render tree (HEEx-friendly). LiveView diffs it.
6. **Explicit over implicit.** Version parsing is dispatch, not `if version == ...`
   scattered across the codebase. Validation is explicit config (`strict|relaxed`).
7. **Small modules, one reason to change.** Target ≤ 250 lines/module; the plan's
   module map is the architecture.
8. **Doc-driven contracts.** All public API has `@moduledoc` + `@doc` + `@spec`;
   `@typedoc` on every struct. `mix doctor` enforces.

### 4.2 Project-wide quality bar

| Gate | Tool | Setting |
|---|---|---|
| Format | `mix format` (Styler optional) | enforced by CI |
| Lint | `mix credo --strict` | no warnings |
| Types | `mix dialyzer` | PLT cache in CI; zero errors |
| Tests | `mix test` + `mix coveralls` | ≥ 95% on `a2ui_core/lib` |
| Docs | `mix docs` | builds with no warnings |
| Boundaries | `mix xref graph` | acyclic module graph |

### 4.3 Security-by-default

A2UI exists to make agent UI "safe like data". The Elixir engine must embody that:

| Threat | Control |
|---|---|
| Malicious component | catalog allowlist; unknown types → placeholder + `UNKNOWN_COMPONENT_TYPE` warning; never crash |
| Huge payload / depth bomb | `max_depth` 50, `max_function_call_depth` 5, `MAX_FUNCTION_CALL_ARGS` 1000, `MAX_ARRAY_INDEX` 10000, `MAX_DYNAMIC_CHILD_LIST_SIZE` 10000 |
| `__proto__` etc. | forbidden at `Pointer` layer |
| ReDoS via agent regex | `is_safe_regex/1` guard (nested quantifiers, unbounded alternation) before `Regex.compile!` |
| `openUrl` phishing | scheme allowlist (`http`, `https`) + `noopener,noreferrer` documented for hosts |
| UAX #31 spoofing | approximated identifier check on all catalog entity names (v1.0) |

## 5. Repo layout

Umbrella project. One supervisor tree is *only* for the example host app; the packages
themselves add zero processes.

```
lab-elixir-a2ui/
├── umbrella/                    # MIX project for monorepo tests/ci
│   └── apps/
│       ├── a2ui_core/           # THIS PLAN
│       ├── a2ui_phoenix/        # renderer adapter
│       ├── a2ui_agent/          # agent SDK (later)
│       └── a2ui_conformance/    # test-only harness (not packaged)
├── example/                     # Demo Phoenix app (separate mix project)
├── reference/                   # upstream repos (read-only)
├── NOTES/research.md
├── SPEC_PIN
└── PLAN.md                      # this file
```

Publish story: `a2ui_core`, `a2ui_phoenix`, `a2ui_agent` are the archives built from
the umbrella's `apps/`; the umbrella itself is never published. `ex_doc` lives at
`docs/` with landing pages on `a2ui.org` patterns.

## 6. `a2ui_core` — module map and contracts

### 6.1 Public API (what users call)

```elixir
alias A2UICore.{Catalog, Processor, Surface}

# Build a processor with one or more catalogs
{:ok, processor} =
  Processor.new(catalogs: [A2UICore.Catalog.Basic.v1_0()])

# Feed raw payload — any of the three wire shapes accepted
{:ok, {processor, effects}} = Processor.process(payload, processor, version: "v1.0")

# Effects: what the host must do
#   {:surface_created, id} | {:surface_deleted, id}
#   {:action, %A2UICore.Outbound.Action{}}
#   {:error, %A2UICore.Error{}}
#   {:rpc_response, %A2UICore.Outbound.RPCResponse{}}
```

### 6.2 Internal architecture

```
A2UICore
├── Version            # semver, protocol versions, catalog compatibility
├── Identifier         # UAX #31 (PCRE approximation, documented)
├── Pointer            # RFC 6901: parse/build/resolve/unescape; forbidden keys
├── Schema             # Draft 2020-12 subset validator (see §7)
├── Error              # struct: category, code, message, path, details
│
├── Message
│   ├── encode         # internal ops → wire (exact JSON per version)
│   ├── decode         # raw → internal ops + version detection
│   ├── operations     # canonical internal ops (structs)
│   └── basic          # v0.9.x / v1.0 adapters
│
├── State
│   ├── data_model          # RFC 6901 store, auto-vivify, cascade notify
│   ├── component           # adjacency map, {id → component}, topology
│   ├── surface             # per-surface state data+components+catalogs
│   └── surface_group       # surface registry, relay bookkeeping
│
├── Catalog
│   ├── loader           # JSON-Schema map → Catalog struct, UAX/license checks
│   ├── schema           # Draft 2020-12 subset validator (incl. `unevaluatedProperties`)
│   ├── functions        # behaviour for function implementation
│   ├── basic            # the shipped basic catalog (18 components, 14 functions)
│   └── expression       # `${...}` template parser (formatString)
│
├── Resolution
│   ├── data_context     # scoped dynamic value evaluation (literal|binding|call)
│   ├── binder           # resolved props, checks → isValid/validationErrors
│   └── node             # flat adjacency map → nested tree for renderers
│
├── Validation
│   ├── payload          # per-catalog component/function schema validation
│   └── integrity        # depth, dangling/orphan/cycle, composition constraints
│
├── Processor            # MessageProcessor + version adapters. Owns inbound,
│                        # transaction semantics for updateComponents.
└── RPC                  # v1.0 bidirectional function calls
```

### 6.3 Key contracts (Elixir sketches)

**Processor** — the entry point:

```elixir
@type message :: A2UICore.Message.Operation.t()
@type effect ::
        {:surface_created, String.t()}
        | {:surface_deleted, String.t()}
        | {:component_batch_validated, ...}
        | {:action, A2UICore.Outbound.Action.t()}
        | {:error, A2UICore.Error.t()}
        | {:rpc_response, map()}

@opaque t :: %Processor{}

@spec new(opts) :: {:ok, t} | {:error, Error.t()}
@spec process(term | [term], t, keyword()) ::
        {:ok, {t, [effect]}} | {:error, Error.t()}
```

- `process/3` accepts a single message map, a bare JSON array, or `{"messages": [...]}`.
- Detects **`version` by sniffing**, then dispatches to the right adapter
  (`A2UICore.Message.adapters() → VersionAdapter.t()`).
- `updateComponents` is **atomic**: validate against a shadow store; only commit on
  success. Rollback is structural: keep two maps, drop the bad one.

**Components & node tree** — LiveView consumes a **plain nested value tree**:

```elixir
%A2UICore.Resolution.Node{
  instance_id: "component-1-0",
  component_id: "the-id-from-payload",
  type: "Button",
  state: :resolved | :pending | :unknown_type | :cyclic,
  props: %{
    text: {:literal, "Submit"} | {:bound, writable?, path, value}
    action: {:action, fn -> ... end}
    # ...
  },
  children: [Node.t()]
}
```

Renderer maps `type` → HEEx function component; unknown types → placeholder + warning.

**DataModel** — pure immutable JSON model, RFC 6901 addressing:

```elixir
@spec set(model, Pointer.t(), term) :: {:ok, model} | {:error, Error.t()}
@spec delete(model, Pointer.t()) :: {:ok, model} | {:error, Error.t()}
@spec get(model, Pointer.t()) :: {:ok, term} | :error
```

Follows the same rules as the reference impl (forbidden keys, 10000 max index,
`~0`/`~1` escaping, auto-vivify, cascade notification). Notifications are implemented
as **subscriptions as data** — a list of `{pattern, reference}` the host holds and
consult for re-render.

**Catalog, pointer, expression** are plain modules with pure functions, as is
`Schema` validation. See research notes.

### 6.4 Error model

A single `A2UICore.Error` struct:

```elixir
%A2UICore.Error{
  category: :validation | :catalog | :integrity | :recursion | :data | :expression | :state,
  code: "VALIDATION_FAILED" | "UNALLOWED_PARENT" | "UNKNOWN_COMPONENT_TYPE" | ...,
  path: String.t() | nil,       # JSON pointer of failing field
  surface_id: String.t() | nil,
  function_call_id: String.t() | nil,
  message: String.t(),
  details: [map()]
}
```

Rendering the boundary: Processing error codes match upstream:
`VALIDATION_FAILED`, `UNALLOWED_PARENT`, `UNALLOWED_CHILD` for structured;
`INVALID_FUNCTION_CALL`, `EXECUTION_ERROR`, `TIMEOUT` etc. for RPC.
Warnings: `MISSING_DATA_BINDING`, `UNKNOWN_COMPONENT_TYPE`, `CYCLIC_REFERENCE`, ...

## 7. Validation: the Draft-2020-12 subset

Ex_json_schema is not usable (draft-07, no `unevaluatedProperties`). We write a
focused, predictable subset inside `a2ui_core`:

Engine: `A2UICore.Schema.Validator`

Supported keywords:
`type`, `properties`, `required`, `additionalProperties`, `unevaluatedProperties`,
`items`, `prefixItems`, `enum`, `const`, `oneOf`/`anyOf`/`allOf`, `$ref`, `$defs`,
`pattern` (with ECMA-262→Erlang `$`→`\z` translation), `propertyNames`,
`patternProperties`, `minLength`/`maxLength`, `minimum`/`maximum`,
`discriminator`, `not`, `default`.

One subtlety: `catalog.json` is a placeholder $ref target in the spec; our validator
resolves it to the surface's active catalog at load time.

Estimated effort ~800 LOC, covered by spec's own `json/` tests + upstream
`common_types.yaml`, `validator_*.yaml` conformance cases.

## 8. `a2ui_phoenix` — renderer adapter

### 8.1 Architecture

- `A2UIPhoenix.SurfaceLiveComponent` — renders one surface, holds `Processor`'s
  surface state in assigns. Pairs with the render-tree from `Resolution.Node`.
- `A2UIPhoenix.Renderer` — maps `node.type` to a function component from
  `A2UIPhoenix.Catalog.Basic` (the 18 basic components). User-extensible via a
  behaviour.
- `A2UIPhoenix.Transport` — implementations for:
  - **LiveView channel** (primary): downstream `createSurface/…` pushes, upstream
    `handle_event("action", ...)` payloads.
  - **SSE plug** (`A2UIPhoenix.Plug.SSE`) for non-LiveView clients.
  - **A2A JSON-RPC plug** (optional peer dep).
- **Effects execution** — translates `Processor` effects into:
  - assigns / socket pushes for the current LiveView;
  - outbound messages on the chosen transport (`action` → agent, `rpc_response` → agent);
  - telemetry events.

### 8.2 Accessibility (per upstream requirement)

| A2UI | HTML |
|---|---|
| `accessibility.label` | `aria-label` |
| `accessibility.description` | `aria-describedby` |
| `accessibility.live` | `aria-live` (`assertive` supported) |
| `accessibility.hidden` | `aria-hidden="true"` + `display:none` |
| component roles | e.g. `Button` → `<button>`, `TextField` → `<input>` + label |

Explicit attributes always override inferred ones. The Phoenix layer renders
warnings visibly in dev.

### 8.3 Wire shape

Client receives JSONL over the assigned transport; each line is one envelope.
The Phoenix adapter decodes entire JSON objects, hands them to `Processor.process/3`.

## 9. `a2ui_agent` — agent SDK (phase 10)

- `A2UIAgent.Prompt` — builds the system prompt from a catalog (and examples).
- `A2UIAgent.Parser` — `<a2ui-json>` envelope extraction (`unwrap/1`), JSON healing
  (`fix_payload/1`), `wrap/1`, `compile/1` → `[Operation]`.
- `A2UIAgent.Streaming` — incremental JSON reader keyed on `progressive_keys`
  (text-like) with **buffering** rules from upstream: components, IDs, `path`, child
  refs, numbers, and `children` are never emitted half-alive.
- `A2UIAgent.Builder` — **import-free** DSL:

  ```elixir
  A2UIAgent.Builder.surface("contact_form_1", catalog)
  |> A2UIAgent.Builder.component("Column", id: "root",
       children: ["title", "form_container"])
  |> A2UIAgent.Builder.text("Contact Us", id: "title")
  ...
  |> A2UIAgent.Builder.to_messages()
  ```

- `A2UIAgent.Validate` — "would a renderer accept this payload?" (stateless check via
  a throwaway processor).

**Express format** (ANTLR DSL) is out of scope for v1; design factory seam for later.

## 10. Testing strategy

1. **Conformance-first**: build `a2ui_conformance` harness in phase 1 with YAML (`yamerl`)
   loading, the `51 action` dispatch table, contains/subset matcher, error matcher,
   skip-list engine. Run all `reference/a2ui/conformance/core/*` suites every CI.
2. **Golden/schema tests**: `common_types_schema`, `agent_to_renderer_schema`,
   `catalog_schema` must equal the committed upstream schemas byte-for-byte after
   canonicalisation (sorted keys). Treat any diff as a spec change, not a test to relax.
3. **Property-based tests** (`stream_data`) for pointer normalize/round-trip,
   schema-validator invariants, expression-parser idempotence.
4. **Unit tests** per phase; doctests encouraged for public API examples.
5. **LiveView tests** for the renderer (`Phoenix.LiveViewTest` + a harness LiveView
   in test support).
6. **Fixture data**: copy the ~40 upstream example JSONs into `a2ui_core/test/fixtures` so
   they run offline in CI without the `reference/` checkout.

## 11. Phase-by-phase plan

Each phase is shippable: tests green, dialyzer clean, docs updated. Size/cost is
author-time estimate; two-person-weeks ⇒ 2 PW.

Live progress and the per-task checklist are in `TODO.md`.

### Phase 0 — Scaffold (1-2 days)

- Umbrella project, `a2ui_core`/`a2ui_conformance` mix apps, CI (format, credo,
  dialyzer, test, coveralls), `SPEC_PIN`, `AGENTS.md` for consistent agent handoff,
  `CODE_OF_CONDUCT.md`, hex metadata placeholders, package naming locked.
- Exit: CI green on `mix test`, credo strict clean, dialyzer clean.

### Phase 1 — Primitives + Conformance harness (≈1 PW)

Modules: `Version`, `Identifier`, `Pointer`, `Schema` (subset), `Error`
+ `a2ui_conformance` harness with skip lists.
- Exit: unit + pointer property tests green; all upstream `core/*` suites load;
  skip-list lists every expected failure as `TODO`.

### Phase 2 — Messages, adapters, wire fidelity (≈1 PW)

Modules: `Message.encode/decode/operations/adapters(v0.9,v1.0)`.
- Exit: every upstream example bundle (43 v1.0 + 43 v0.9.1) and both JSONL samples
  decode, validate against the bundle schema (`sample.json`) and round-trip through the
  encoder; the ajv-calibrated spec cases (`specification/*/test/cases`) replay with the
  same verdicts; vendored schemas equal the pinned reference; conformance
  `agent_to_renderer_schema`/`common_types_schema`/`validate_common_type` (25 cases)
  green.

### Phase 3 — State (≈2 PW)

Modules: `DataModel`, `Component`, `Surface`, `SurfaceGroup`, `Validation.integrity`.
- Exit: conformance `data_model` (51) and `resolve_path` (15: `data_context.yaml` plus the
  4 in `message_processor_v0_9.yaml`) green; topology/integrity invariants unit-tested.
  (`data_model_pointers.yaml` and `data_deletion.yaml` use `action: validate`, so they
  belong to Phase 5.)

### Phase 4 — Catalog, functions, expression (≈2 PW)

Modules: `Catalog.loader`, `Catalog.functions` (behaviour), `Catalog.basic`,
`Catalog.expression`, `Formatter` behaviour + `:intl` impl.
- Exit: conformance `from_json`, `catalog_schema`, `evaluate_function` and
  `parse_expression_template` (≈185 runnable cases across `catalog.yaml`,
  `functions.yaml`, `expressions.yaml`) green; UAX31 approximation covered by property
  tests.

### Phase 5 — Processor (≈2 PW)

Modules: `Processor`, `Resolution.data_context`, `Resolution.binder`,
`Validation.payload`.
- Exit: every `validate`, `process_messages`, `get_renderer_capabilities`,
  `get_renderer_data_model`, `select_catalog` and `dispatch_action` case (≈184 runnable:
  `validator_v0_9/v1_0`, `message_processor_v0_9/v1_0`, `data_deletion`,
  `data_model_pointers`, `composition_constraints`, `index_function`,
  `validation_result`, `reserved_keys`, `multi_catalog`, `actions`, and the `validate`
  cases of `functions`/`expressions`) green; `updateComponents` is atomic (test
  intentionally failing batches). Includes the generic binder, which the harness uses to
  compare resolved component props.

### Phase 6 — Node resolution (≈1 PW)

Modules: `Resolution.Node`, accessibility checks.
- Exit: `node_resolution.yaml` (8) and `accessibility.yaml` (6) green; placeholders/cycles
  handled; ids stable. (The Python harness does not run these; semantics come from the TS
  and Dart harnesses and the spec.)

### Phase 7 — RPC v1.0 (≈1 PW)

Modules: `RPC`, `RendererFunctionResponse`, updates to `Processor` for
`callRendererFunction`/`agentFunctionResponse`.
- Exit: `rpc_functions.yaml` (15 `handle_rpc` cases) green. (The 3 `extensions/a2a`
  `handle_rpc` cases belong to Phase 9.)

### Phase 8 — `a2ui_phoenix` (≈2 PW)

LiveComponent, renderer, basic catalog as function components, LiveView channel transport.
- Exit: a LiveView skeleton app renders the 43 `catalogs/basic/v1/examples/*` without
  errors; demo contact-form works end-to-end; a11y attributes present.

### Phase 9 — `a2ui_phoenix` transports (≈2 PW)

Plug.SSE, Plug.A2A (optional peer dep), transport contract tests.
- Exit: SSE smoke test + A2A interop test (using upstream sample agent as backend).

### Phase 10 — `a2ui_agent` (≈3 PW)

Prompt, parser, streaming, builder. The streaming part carries 118 conformance cases —
budget real time.
- Exit: `agent/direct_json/*` suites green (streaming buffered properly).

### Phase 11 — Release (≈1 PW)

Docs, guides, changelog, publish `0.1.0` of all three packages, sample README screen
recordings, `SPEC_PIN` updated to latest compatible spec commit.

## 12. Risk register

| Risk | Impact | Mitigation |
|---|---|---|
| Existing `a2ui` package name / namespace collision | High | We already chose different names; document non-coexistence; still respect upstream semantics. |
| JSON-Schema subset correctness | High | conformance `catalog.yaml` gates it; fuzz user-defined catalogs. |
| Streaming parser (118 cases) | Medium | isolated module, table-driven tests, regular conformance gate. |
| Spec churn (v1.0 still a candidate) | Medium | pin `SPEC_PIN`, keep adapters narrow, track upstream; each run of upstream tests is deterministic. |
| ECMA-262 regex semantics | Medium | port `isSafeRegex`; escape `$`→`\z` only outside classes (edge documented). |
| Performance on huge surfaces | Medium | benchmark render/reconciliation in phase 8; keep hot paths linear/flat loops. |
| Missing v1.0 clients | Low | the agent and renderer sides share core; users can stay on v0.9.1 interop until ready. |

## 13. Non-goals for v1

- v0.8 support (kept as a documented adapter seam; lives in `A2UICore.Legacy` if/when).
- Express DSL port.
- `MCP` binding (separate package later).
- Renderer UI themes (host app's CSS does it).

## 14. Open questions

1. **Names final?** `a2ui_core`, `a2ui_phoenix`, `a2ui_agent` are free; confirm before CI/publish scaffolding.
2. **License:** decided — Apache-2.0 for our code, the license of upstream too.
3. **JS hooks?** Default recommendation: server-only for v1 (simplest, matches LiveView);
   local actions like `openUrl` executed client-side need a small hook — phase 8.
4. **Built-in catalog ownership** — same design as upstream: ship 18 components; custom
   catalogs are registered by hosts. No hard coupling.
5. **Sample app location** — keep `example/` separate mix project to avoid mixing app
   dependencies into the umbrella CI matrix.
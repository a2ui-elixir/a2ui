# A2UI Research Notes

Condensed findings from studying the upstream repos (cloned at `reference/`) and a2ui.org.

## Sources

| Repo | Path | Notes |
|---|---|---|
| `a2ui-project/a2ui` | `reference/a2ui` | Specs, catalogs, SDKs (TS/Py/Dart/Kotlin/Swift), renderers, conformance suite. Commit `ce03d00`, 2026-10-10. |
| `a2ui-project/composer` | `reference/composer` | Visual A2UI authoring workbench (Angular shell + postMessage bridge). |
| a2ui.org | web | Landing page, version table, evolution guides. |

Those are the only two repos in the `a2ui-project` GitHub org.

## Versions

| Version | Status | Path |
|---|---|---|
| v0.8 | Legacy | `specification/v0_8/` |
| v0.9 | Stable | `specification/v0_9/` |
| v0.9.1 | **Current production** | `specification/v0_9_1/` |
| v1.0 | Release candidate | `specification/v1_0/` + `catalogs/basic/v1/` |

`specification/v0_9_1/json/` is byte-identical to `v0_9/json/` except the `version`
field widened from `const "v0.9"` to `enum ["v0.9","v0.9.1"]` in 3 files. All `$id`s
in the v0.9.1 dir still say `v0_9`. Capability namespace keys are `"v0.9"` and `"v1.0"`.

## Message types

**Agent -> renderer** (always `{version, <key>}` and nothing else):

| Key | v0.9.1 | v1.0 |
|---|---|---|
| `createSurface` | yes | yes (+ inline `components`, `dataModel`, `metadata.extensions`; `catalogId` now optional; `theme` removed) |
| `updateComponents` | yes | yes |
| `updateDataModel` | yes (`value` optional) | yes (`value` **required**, `null` deletes) |
| `deleteSurface` | yes | yes |
| `callRendererFunction` | — | yes |
| `agentFunctionResponse` | — | yes |

**Renderer -> agent**: `action`, `error` (v0.9.1); plus `callAgentFunction`,
`rendererFunctionResponse` (v1.0). Also exactly two top-level keys.

Wire shapes accepted by all implementations: single object, bare JSON array, or
`{"messages": [...]}`. The list/wrapper carry no `version` of their own.

## v0.9.1 -> v1.0 deltas that matter for an implementation

1. **Directive syntax** — `DataBinding` key `"path"` -> `"@path"`; `FunctionCall`
   `"call"` -> `"@call"`; `returnType` removed from the wire; `catalogId` added
   (optional on function calls, required inside `callRendererFunction.callFunction`).
   **NOT renamed:** `updateDataModel.path` and `ChildList` template `path`.
2. **Bidirectional function calls (RPC)** with `functionCallId` correlation,
   `allowedCallers` (`rendererOnly` | `agentOnly` | `rendererOrAgent`),
   `requiresUserActivation`.
3. **Single-message instantiation** — `createSurface` can carry the whole tree.
4. **Theming removed** — `theme` gone; styling is entirely the host framework's job.
5. **ValidationResult** — v0.9 check functions return booleans; v1.0 return
   `{valid, code?, message?, severity?}`.
6. **UAX #31** identifier enforcement on all catalog entity names, plus
   component/function/argument names. Reserved `@` namespace (`@path`, `@call`,
   `@index`), escaped by doubling (`@@path`).
7. **Composition constraints** — `allowedParents` / `allowedChildren`, with
   `UNALLOWED_PARENT` / `UNALLOWED_CHILD` error codes.
8. **New common types** — `CallId`, `Extensions`, `Child`, `FunctionCommon`,
   `IndexSystemFunction`, `Surface`, `FunctionResponse`.
9. **Accessibility** gains `live` (`off|polite|assertive`) and `hidden`.
10. **Actions** gain `userMessage`; action envelope gains `metadata.extensions`.

## Core engine shape (mirrors `typescript/web_core` + `python/a2ui_core`)

```
MessageProcessor
└── SurfaceGroupModel                map of surfaces, relays actions
    └── SurfaceModel                  data_model + components_model + catalogs
        ├── DataModel                RFC 6901 store, auto-vivify, cascade notify
        └── SurfaceComponentsModel   flat Map<id, ComponentModel>, topology checks
ComponentModel                       id, type, mutable properties

DataContext      scoped dynamic value resolution (literal | DataBinding | FunctionCall)
ComponentContext component + scoped DataContext + dispatch_action
GenericBinder    props resolution, checks -> isValid/validationErrors, action closures
NodeResolver     flat map -> reactive node tree, placeholders, cycle guards, templates
PayloadValidator component/function/theme schema validation
IntegrityChecker depth limits (50), function-call depth (5), dangling/orphan/cycle
VersionAdapter   v0.8 / v0.9 / v1.0 -> canonical internal operations
Catalog          JSON Schema catalog: components map, functions map, allowed_callers
```

Key semantics to preserve:
- **Literal vs binding is decided by dict shape, not a tag.** `{"path": ...}` /
  `{"@path": ...}` / `{"call": ...}` / `{"@call": ...}` key presence, and objects
  carrying `componentId` are excluded.
- **`updateComponents` is atomic**: validate the whole batch against a shadow store
  first; on failure the live store is untouched.
- **Progressive rendering**: render as soon as a valid `root` component exists;
  buffer otherwise; placeholders for missing refs; cycle -> `CYCLIC_REFERENCE`.
- **Cascade notification**: a write to `/a` invalidates `/a`, `/a/*`, and ancestors.
- **Data model**: `~0`/`~1` unescaping, forbidden keys
  (`__proto__`/`constructor`/`prototype`), `MAX_ARRAY_INDEX = 10000`,
  own-property checks, null deletes.
- **Missing bindings** emit a `MISSING_DATA_BINDING` warning, not an error.
- **Capability resolution is strict**: component/function `catalogId` -> surface
  `catalogId` -> error. No fallback to advertised catalogs.

## Basic catalog functions (v1.0, 14 + system)

`required`, `regex`, `length`, `numeric`, `email`, `formatString`, `formatNumber`,
`formatCurrency`, `formatDate`, `pluralize`, `openUrl`, `and`, `or`, `not`, plus the
system function `@index`. 18 components: `Text, Image, Icon, Video, AudioPlayer, Row,
Column, List, Card, Tabs, Modal, Divider, Button, TextField, CheckBox, ChoicePicker,
Slider, DateTimeInput`.

## Conformance suite (`conformance/`)

51 YAML files, validated by `conformance_schema.json` (20 case shapes, 51 `action`
values). `core/` covers validator + message_processor per version, data_model (51
cases), data_model_pointers, data_deletion, data_context, expressions (89), functions
(60), catalog (47), common_types (22), actions, rpc_functions, multi_catalog,
composition_constraints, reserved_keys, index_function, validation_result,
accessibility, node_resolution. `agent/` covers the agent SDK per inference format.

Assertions are **contains/subset**, not exact, except for the schema-emission cases
(`common_types_schema`, `agent_to_renderer_schema`, `catalog_schema`) which compare
canonical JSON for exact equality against `specification/<ver>/json/*.json`.

Harnesses must declare `SUPPORTED_PROTOCOL_VERSIONS` and `SKIP_TEST_NAMES`.

## Elixir-specific constraints found

| Need | Finding |
|---|---|
| UAX #31 | Corrected later: PCRE2 10.4x (Erlang/OTP 28 and later) **has** `\p{XID_Start}`/`\p{XID_Continue}`, and they agree with Python's `str.isidentifier()` where the approximation `^[\p{L}\p{Nl}_][\p{L}\p{Nl}\p{Mn}\p{Mc}\p{Nd}\p{Pc}]*$` does not (U+2118, U+00B7, U+0E33, U+037A, U+1885). The approximation remains only for older PCRE. |
| JSON Schema | No Draft 2020-12 library. `ex_json_schema` is 0.11.5 (draft-07 era, no `unevaluatedProperties`/`prefixItems`). `spark` is a DSL, not a validator. -> implement our own validator (it now passes the official draft 2020-12 test suite). |
| `$` in `pattern` | JSON Schema `pattern` is ECMA-262; translate `$` -> `\z` outside character classes (same trick web_core uses). |
| YAML | `yamerl ~> 0.10` (pure Erlang) for the conformance harness. |
| Intl formatting | `intl ~> 1.0` available for `formatNumber`/`formatCurrency`/`formatDate`/`pluralize`. |
| JSON | `jason ~> 1.4`. |
| Toolchain present | Elixir 1.20.4 / OTP 29 / Hex 2.5.1. |
| Reactivity | No need to port `preact/signals`. LiveView's own assign/change-tracking is the reactive layer. |

## Existing Hex ecosystem (found during writing, verify before phase 0)

- `a2ui` v0.3.0 (actioncard/a2ui-elixir): v0.9-only; single package; 18-function-component
  renderer over LiveView, `use A2UI.Live`/`use A2UI.Agent` macros, Local/SSE/JSON-RPC/A2A
  transports, ~3.7K LOC, own roadmap (SPEC.md) with WebSocket/REST/AG-UI planned/missing.
  No v0.9.1 specifics, no v1.0, no JSON-Schema catalog validation, no conformance suite
  harness, no RPC, no composition constraints, no multi-catalog, no expression parser,
  no agent-side inference formats, no UAX #31, no theming strategy.
- Free hex names (checked 2026-10-12): `a2ui_core`, `a2ui_phoenix`, `a2ui_agent`,
  `a2ui_live`, `phoenix_a2ui`, `a2ui_protocol`, `a2ui_ex`.
- Namespace collision warning: actioncard's package owns the `A2UI` top-level module
  (`lib/a2ui.ex`). Any new package family must either choose `A2UI.Core`/`A2UI.Phoenix`...
  (still collision-prone at the `A2UI` module itself) or document mutual exclusion with
  `a2ui` 0.x in one app.
# AGENTS.md — lab-elixir-a2ui

## What this repo is

Elixir/Phoenix implementation of the [A2UI protocol](https://a2ui.org) — build plan in
`PLAN.md`, distilled research in `NOTES/research.md`, upstream reference clones in
`reference/` (gitignored; how to re-clone is in the README).

## Invariants (do not break these)

1. **Module namespaces**: `A2UICore.*` (core), `A2UIPhoenix.*` (renderer), `A2UIAgent.*`
   (agent SDK), `A2UIConformance.*` (test harness). Never create a bare `A2UI` module —
   it collides with the published `a2ui` Hex package. Hex package names are `a2ui_core`,
   `a2ui_phoenix`, `a2ui_agent`.
2. **`a2ui_core` is pure;** no processes, no Phoenix/Plug deps. Processes belong to
   `a2ui_phoenix` boundaries (LiveView/channel/plugs).
3. **Target protocol versions: v0.9/v0.9.1 + v1.0** (adapters per version; no v0.8).
4. License: **Apache-2.0** for our code, the license of the upstream spec too.
5. Conformance suites are the source of truth: when in doubt, run
   `mix test` in `apps/a2ui_conformance` and match reference behavior
   (`reference/a2ui` pin recorded in `SPEC_PIN`).
6. Every public module/function has `@moduledoc`/`@doc`/`@spec`; CI gates
   `mix format --check-formatted`, `mix credo --strict`, `mix dialyzer`,
   `mix coveralls --max-failures=0` (run from `umbrella/`, `MIX_ENV=test`).

## Build & test commands

```bash
cd umbrella
mix deps.get
mix compile --warnings-as-errors
mix test                       # all apps
mix coveralls --max-failures=0 # incl. per-test coverage gate
mix credo --strict
mix dialyzer                   # first run builds the PLT (slow)
```

## Repo map

```
umbrella/apps/a2ui_core          # protocol engine (pure Elixir)
umbrella/apps/a2ui_conformance   # YAML suite runner against reference/
umbrella/apps/a2ui_phoenix       # LiveView adapter (Phase 8+)
umbrella/apps/a2ui_agent         # Agent SDK (Phase 10)
reference/a2ui                   # upstream spec + conformance (pinned, see ../SPEC_PIN)
```

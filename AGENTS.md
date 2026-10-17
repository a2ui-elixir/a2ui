# AGENTS.md — A2UI for Elixir

## What this repo is

Elixir/Phoenix implementation of the [A2UI protocol](https://a2ui.org), published to Hex
as `a2ui_core`, `a2ui_phoenix` and `a2ui_agent` (github.com/a2ui-elixir/a2ui). The
original build plan is in `PLAN.md`, distilled research in `NOTES/research.md`, upstream
reference clones in `reference/` (gitignored; how to re-clone is in `CONTRIBUTING.md`).

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
   `mix coveralls --umbrella` (run from `umbrella/`, `MIX_ENV=test`).

## Build & test commands

```bash
cd umbrella
mix deps.get
mix compile --warnings-as-errors
mix test                                   # all apps
MIX_ENV=test mix coveralls --umbrella      # tests + coverage gate (95% minimum)
mix credo --strict
mix dialyzer                               # first run builds the PLT (slow)
(cd apps/a2ui_phoenix && node --test test/js/*.test.mjs)   # browser script, sandbox page
```

The fidelity and conformance suites need the pinned upstream checkout at
`reference/a2ui` (see `CONTRIBUTING.md`). Set `A2UI_REFERENCE_ROOT` to point elsewhere and
`A2UI_REQUIRE_REFERENCE=1` to make a missing checkout a failure instead of a silent
zero-test run (CI does).

Do **not** pass `--max-failures=0` to `mix test`/`mix coveralls`: ExUnit then stops
before running anything and exits 0.

Each publishable app builds its own docs (`mix docs --warnings-as-errors` in
`apps/a2ui_core`, `apps/a2ui_phoenix` and `apps/a2ui_agent`; CI checks this). Its
guide lives in `guides/`, and every code example in a guide must run as written. A
package build of `a2ui_phoenix` or `a2ui_agent` needs `A2UI_HEX_BUILD=1`, so that
`a2ui_core` becomes a Hex requirement instead of the sibling app (`CONTRIBUTING.md`,
Releasing).

Progress and the working task list live in `TODO.md`; deliberate deviations from the
reference live in `NOTES/divergences.md`.

## Repo map

```
umbrella/apps/a2ui_core          # protocol engine (pure Elixir)
umbrella/apps/a2ui_conformance   # YAML suite runner against reference/
umbrella/apps/a2ui_phoenix       # LiveView renderer, SSE plug
umbrella/apps/a2ui_agent         # agent SDK, A2A server
reference/a2ui                   # upstream spec + conformance (pinned, see SPEC_PIN)
```

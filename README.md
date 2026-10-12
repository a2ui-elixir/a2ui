# lab-elixir-a2ui

A spec-faithful, multi-version Elixir/Phoenix implementation of the
[A2UI protocol](https://a2ui.org) (v0.9 / v0.9.1 and v1.0).

| Package | Namespace | Status |
|---|---|---|
| `a2ui_core` | `A2UICore.*` | Protocol engine (pure Elixir, Jason only). Phase 2 done: wire messages, schema validation, version adapters. |
| `a2ui_conformance` | `A2UIConformance.*` | Test harness running the upstream YAML conformance suites. |
| `a2ui_phoenix` | `A2UIPhoenix.*` | LiveView renderer — not started. |
| `a2ui_agent` | `A2UIAgent.*` | Agent SDK — not started. |

Start with `PLAN.md` (design and phases), `TODO.md` (live task list),
`AGENTS.md` (invariants and commands) and `NOTES/` (research, divergences).

## Getting the upstream reference

The fidelity and conformance suites run against a pinned checkout of
[a2ui-project/a2ui](https://github.com/a2ui-project/a2ui) at
`reference/a2ui` (gitignored; the commit is recorded in `SPEC_PIN`):

```bash
pin=$(awk '/commit:/ {print $NF}' SPEC_PIN)
git init reference/a2ui
git -C reference/a2ui fetch --depth 1 https://github.com/a2ui-project/a2ui.git "$pin"
git -C reference/a2ui checkout --detach FETCH_HEAD
```

Environment variables:

- `A2UI_REFERENCE_ROOT` — absolute path of the checkout (default: found by walking up
  to `reference/a2ui`).
- `A2UI_REQUIRE_REFERENCE=1` — fail instead of silently generating zero tests when the
  checkout is missing (CI sets this).

## Develop

```bash
cd umbrella
mix deps.get
mix test                                  # all apps
MIX_ENV=test mix coveralls --umbrella     # tests + coverage gate
mix format --check-formatted
mix compile --warnings-as-errors
mix credo --strict
mix dialyzer                              # first run builds the PLT
```

## License

Apache-2.0 (`LICENSE`), the license of the upstream specification and
conformance suites too.

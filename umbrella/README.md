# A2UI for Elixir (umbrella)

Spec-faithful Elixir implementation of the [A2UI protocol](https://a2ui.org), v0.9 /
v0.9.1 and v1.0.

- `apps/a2ui_core` — protocol engine (`A2UICore.*`): wire messages, schema validation,
  version adapters; pure Elixir with Jason as the only runtime dependency.
- `apps/a2ui_conformance` — harness running the upstream YAML conformance suites.
- `apps/a2ui_phoenix` — LiveView renderer (not started).
- `apps/a2ui_agent` — agent SDK (not started).

See the repository `README.md`, `PLAN.md` and `TODO.md` one level up for the plan, the
task list, and how to fetch the pinned upstream reference the test suites run against.

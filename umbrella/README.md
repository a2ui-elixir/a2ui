# A2UI for Elixir (umbrella)

Elixir implementation of the [A2UI protocol](https://a2ui.org), protocol versions
v0.9, v0.9.1 and v1.0.

- `apps/a2ui_core`: the protocol engine (`A2UICore`). Messages, catalogs, surface
  state, node resolution and function calls; pure Elixir, with Jason as its only
  dependency.
- `apps/a2ui_phoenix`: the LiveView renderer (`A2UIPhoenix`).
- `apps/a2ui_agent`: the agent SDK (`A2UIAgent`), including an A2A server.
- `apps/a2ui_conformance`: the harness that runs the upstream YAML conformance
  suites.

`CONTRIBUTING.md` one level up covers fetching the pinned upstream reference
the test suites run against, the commands, releasing, and bumping `SPEC_PIN`.

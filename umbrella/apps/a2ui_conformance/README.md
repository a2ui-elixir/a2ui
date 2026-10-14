# A2UIConformance

The test harness that runs the upstream A2UI conformance suites
(`reference/a2ui/conformance`, YAML) against `a2ui_core` and `a2ui_agent`. It is
part of this repository's test setup and is not published.

Each case is dispatched by its suite family and action to a handler in
`A2UIConformance.Handlers`, which ports the reference harness for that action
(mostly `python/a2ui_core/tests/test_conformance.py`). A case runs, or is
skipped with a reason the harness computes:

- a protocol version outside v0.9, v0.9.1 and v1.0 (v0.8 is out of scope);
- an optional family this project does not implement (the Express format, the
  legacy agent SDK, ADK integration);
- an explicit entry in `A2UIConformance.SkipPolicy`, which must match a real
  case, so a stale entry fails the run.

An action the harness has no vocabulary for fails rather than being skipped.

## Running

From `umbrella/`, with the pinned checkout in place (see the repository README):

```bash
cd apps/a2ui_conformance
A2UI_REQUIRE_REFERENCE=1 mix test
```

`A2UI_REFERENCE_ROOT` points to a checkout somewhere else.

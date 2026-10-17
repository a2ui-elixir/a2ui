# lab-elixir-a2ui

An Elixir implementation of the [A2UI protocol](https://a2ui.org), protocol
versions v0.9, v0.9.1 and v1.0: a protocol engine, a Phoenix LiveView renderer
and an agent SDK, checked against the upstream conformance suites.

| Package | Namespace | What it is |
|---|---|---|
| `a2ui_core` | `A2UICore` | Protocol engine: messages, catalogs, surface state, node resolution, function calls. Pure Elixir; Jason is its only dependency. |
| `a2ui_phoenix` | `A2UIPhoenix` | LiveView renderer: the basic catalog as function components, two-way bindings, actions, and an SSE plug. |
| `a2ui_agent` | `A2UIAgent` | Agent SDK: catalog negotiation, prompts in the direct JSON and Express formats, validated parsing of streamed model output, skills, and an A2A server. |
| `a2ui_conformance` | `A2UIConformance` | Test harness for the upstream YAML conformance suites. Not published. |

Each package has a README and a guide under `umbrella/apps/*/guides`.
`PLAN.md` holds the design, `TODO.md` the task list, `AGENTS.md` the
invariants and commands, and `NOTES/` the research and the deliberate
divergences from the reference implementations.

## Examples

`examples/` holds three applications that use the packages together: a
restaurant-finder agent served over A2A, MCP, AG-UI, server-sent events and
WebSocket; a Phoenix LiveView gallery whose scenarios cover the protocol,
with the upstream example surfaces and a live chat with that agent; and a
renderer that draws surfaces in the terminal. `examples/README.md` says how to
run them and which features each one exercises.

## Landing page

`site/` is the project's landing page, a small Phoenix application
(`mix phx.server`, port 4040) that `mix site.build` exports as static files
for any host. What it says about the packages is tested against this
repository, and its Examples section plays recorded runs of the examples
(`mix gallery.replays` in `examples/gallery`); `site/README.md` has the
details.

## Conformance

Of the 1144 upstream cases at the pinned commit (`SPEC_PIN`), 946 run and all
of them pass. The others are skipped, each for a stated reason:

| Suite family | Cases | Run | Skipped |
|---|---:|---:|---|
| `core` | 572 | 533 | 39 for protocol v0.8 |
| `agent` (shared suites) | 107 | 107 | none |
| `agent/direct_json` | 163 | 124 | 39 for v0.8 catalogs |
| `agent/express` | 115 | 115 | none |
| `agent/builder` | 11 | 11 | none |
| `agent/macros` | 18 | 18 | none |
| `agent/legacy` | 133 | 25 | 67 whose rules the blueprint suites replaced, 39 for protocol v0.8, 2 in the Elemental and Atom formats |
| `extensions/a2a` | 14 | 13 | 1 v0.8 payload |
| `extensions/adk` | 11 | 0 | adapters for Google's Python ADK |

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

- `A2UI_REFERENCE_ROOT`: absolute path of the checkout (default: found by walking up
  to `reference/a2ui`).
- `A2UI_REQUIRE_REFERENCE=1`: fail instead of silently generating zero tests when the
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

Each publishable package builds its own documentation:

```bash
cd umbrella/apps/a2ui_core && mix docs    # likewise a2ui_phoenix and a2ui_agent
```

## Releasing

The three packages share a version. `a2ui_phoenix` and `a2ui_agent` depend on
`a2ui_core`: on the sibling app inside this repository, and on the Hex release
in the published package. `A2UI_HEX_BUILD=1` selects the Hex release for a
build:

```bash
cd umbrella/apps/a2ui_core && mix hex.build
cd ../a2ui_phoenix && A2UI_HEX_BUILD=1 mix hex.build
cd ../a2ui_agent && A2UI_HEX_BUILD=1 mix hex.build
```

To release:

1. Set the version in the three `mix.exs` files, and give the version's
   section in each `CHANGELOG.md` its date.
2. Check that `@source_url` in the three `mix.exs` files is this project's
   repository. The docs link source files to the tag `v<version>` there.
3. Tag the commit `v<version>` and push the tag.
4. Publish from a fresh clone of the tag, `a2ui_core` first. `mix hex.publish`
   compiles `a2ui_phoenix` and `a2ui_agent` and their docs against the Hex
   release of `a2ui_core`, so those two fetch it before they publish, which
   adds it to `umbrella/mix.lock`; the clone keeps that out of your checkout:

   ```bash
   git clone --branch v<version> https://github.com/a2ui-elixir/a2ui.git a2ui-release
   cd a2ui-release/umbrella && mix deps.get
   (cd apps/a2ui_core && mix hex.publish)
   for app in a2ui_phoenix a2ui_agent; do
     (cd apps/$app && A2UI_HEX_BUILD=1 mix deps.get && A2UI_HEX_BUILD=1 mix hex.publish)
   done
   ```

## Bumping `SPEC_PIN`

1. Check out the new upstream commit:

   ```bash
   new=<commit>
   git -C reference/a2ui fetch --depth 1 https://github.com/a2ui-project/a2ui.git "$new"
   git -C reference/a2ui checkout --detach FETCH_HEAD
   ```

2. Run the vendored-drift test. It fails for every schema or catalog under
   `umbrella/apps/a2ui_core/priv` that differs from the checkout, and for
   schema files added or removed upstream:

   ```bash
   cd umbrella/apps/a2ui_core
   A2UI_REQUIRE_REFERENCE=1 mix test --only vendored_drift
   ```

3. Copy the changed files over. Run this from the repository root:

   ```bash
   ref=reference/a2ui
   priv=umbrella/apps/a2ui_core/priv
   for v in v0_9 v0_9_1 v1_0; do
     rm "$priv/schemas/$v"/*.json
     cp "$ref/specification/$v/json"/*.json "$priv/schemas/$v/"
   done
   cp "$ref/specification/v0_9_1/catalogs/basic/catalog.json" "$priv/catalogs/basic_v0_9_1.json"
   cp "$ref/catalogs/basic/v1/catalog.json" "$priv/catalogs/basic_v1_0.json"
   cp "$ref/specification/v1_0/test/testing_catalog.json" "$priv/catalogs/testing_v1_0.json"
   ```

4. Record the commit, its date and what was checked in `SPEC_PIN`.
5. Run the full gate (the commands under Develop) with
   `A2UI_REQUIRE_REFERENCE=1`. The conformance suite also fails on an
   action the harness does not know and on an explicit skip in
   `A2UIConformance.SkipPolicy` that no longer matches a case.
6. Fix what fails, or skip a case in `A2UIConformance.SkipPolicy` with the
   reason. Record deliberate differences from the reference in
   `NOTES/divergences.md`, update the scoreboard above, and commit.

## License

Apache-2.0 (`LICENSE`), the license of the upstream specification and
conformance suites too. The JSON schemas and catalogs under
`umbrella/apps/a2ui_core/priv` are copies of the specification's files, with
its license file (`priv/LICENSE-APACHE`).

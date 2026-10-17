# Contributing

The packages live in an umbrella project under `umbrella/`; the examples and
the landing page are separate Mix projects that use them by path.
[`AGENTS.md`](AGENTS.md) lists the rules the code keeps (namespaces, a pure
`a2ui_core`, documentation on every public function), and the conformance
suites are the source of truth for behavior.

## The upstream reference

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
MIX_ENV=test mix coveralls --umbrella     # tests + coverage gate (95% minimum)
mix format --check-formatted
mix compile --warnings-as-errors
mix credo --strict
mix dialyzer                              # first run builds the PLT
(cd apps/a2ui_phoenix && node --test test/js/*.test.mjs)   # browser script, sandbox page
```

Do not pass `--max-failures=0` to `mix test` or `mix coveralls`: ExUnit then
stops before running anything and exits 0.

Each publishable package builds its own documentation, and CI builds it with
warnings as errors. Each package's guide lives in its `guides/`, and every
code example in a guide must run as written.

```bash
cd umbrella/apps/a2ui_core && mix docs --warnings-as-errors   # likewise a2ui_phoenix and a2ui_agent
```

The examples and the landing page have their own tests:

```bash
(cd examples/restaurant_agent && mix test)
(cd examples/terminal_client && mix test)
(cd examples/gallery && mix test)
(cd site && mix test)
```

Deliberate differences from the reference implementations go in
`NOTES/divergences.md`, with the reason.

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

1. Set the version in the three `mix.exs` files and in the `hostInfo` of
   `umbrella/apps/a2ui_phoenix/priv/static/a2ui_phoenix.js`, and give the
   version's section in each `CHANGELOG.md` its date.
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
   `NOTES/divergences.md`, update the conformance table in `README.md` and
   the landing page's figures (`site/lib/site/content.ex`), and commit.

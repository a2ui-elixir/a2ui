# Deliberate divergences from the reference implementations

Where this port intentionally differs from the Python/TypeScript reference, and why.
Conformance suites remain the source of truth; every entry here is either invisible to
them or documented as a skip with a reason.

## Schema validation

- **`format` is an annotation by default.** The Python SDK validates without a
  `FormatChecker`, so `format: "uri"` never fails there; the upstream spec test runner
  uses ajv with ajv-formats, which does assert it. `A2UICore.Schema.validate/3` takes
  `formats: :assert` for the latter; the spec-case replay uses it (one case,
  `openUrl: Invalid URL format (not a URI)`, depends on it).
- **`unevaluatedItems` raises.** No A2UI schema uses it; supporting it would need
  array-item annotation tracking that nothing exercises.
- **2020-12 meta-schema is bound to `true`** when validating v1.0 catalog documents
  (`catalog_definition.json` embeds schemas by `$ref` to it). Supporting the real
  meta-schema needs `$dynamicRef`, which the engine does not implement. Verdicts match
  ajv on all upstream cases because none of them carries a malformed embedded schema.
- **Leading `]` in a character class is a literal** (`[]a]`, `[^]a]`), as in the
  reference's PCRE-style `regex` module, not an empty / any-character class as in
  ECMA-262. No A2UI schema or catalog uses either form.

## Messages

- **`nil` payload decodes to `{:ok, []}`** (TypeScript behaviour). The Python factory
  rejects it.

## State

- **Writes are atomic on error.** Python's `DataModel.set` can leave a partial write
  behind when a later path segment fails. No conformance case reads state after an
  error step, so this is invisible to the suites; the Elixir port returns the original
  model on error.
- **Observers do not hold live references.** In Python an observer registered before
  `dispose/1` sees in-place mutations afterwards. An immutable model cannot reproduce
  that, and no case asserts it.
- **Deterministic iteration order.** Components, child properties and object keys are
  visited in sorted order (`Components.to_list/1`, `RefSpec.extract/2`,
  `Topology`), not JSON insertion order, because Elixir maps are unordered. When a
  graph has several violations the one reported is therefore stable but may differ
  from the reference's first-inserted choice. Conformance cases carry one violation
  each; only messages are asserted.
- **Child-reference property paths** put subscripts directly after the key
  (`children[0]`, `tabs[1].child`, `items[0][1]`); the reference joins nested lists
  with a dot in a few unexercised shapes.
- **`$ref` cycles are cut.** `Catalog.ReferenceMap` stops on a `$ref` it is already
  expanding; the Python analysis would recurse until it hits the interpreter limit.

## Catalogs

- **Key order comes from ordered input.** Python dicts keep the order a document was
  read in, which orders a catalog's components and functions (and so the
  `anyComponent` / `anyFunction` unions) and every key `to_json` writes. Elixir maps
  have no order: a catalog read from a `Jason.OrderedObject`
  (`Jason.decode(text, objects: :ordered_objects)`) keeps its document's order, and
  `Catalog.to_json(catalog, ordered: true)` writes it back in the reference's order; a
  catalog read from a map lists its entries, and writes its keys, by name. Comparisons in
  the harness ignore key order and the order of `enum` values and `required` names, as
  the reference harness does.
- **Peers are identified by value.** Python tells peer catalogs apart by object
  identity. A catalog value has none, so a peer is identified by its catalog id, `$id`
  and the names of its components and functions; two catalogs that agree on all four
  count as one peer.
- **`inf` / `nan` strings are not numbers.** Python's `float("inf")` succeeds; the BEAM
  has no non-finite floats, so `Coerce.to_float/1` rejects them and the numeric
  functions treat them as non-numeric.

## Functions and expressions

- **Locale data.** `A2UICore.Formatter.Default` formats every locale as `en-US` (the
  only one the suites exercise; Python falls back to it for unknown locales too).
  Hosts that need CLDR data plug in their own `A2UICore.Formatter` module.
- **Errors are values.** Where the reference raises while resolving a dynamic value
  (reserved keys, failing functions, unknown catalogs), `DataContext.resolve_dynamic_value/2`
  returns `nil` plus an `{:error, %{code: "EXPRESSION_ERROR", …}}` effect, so one bad
  binding cannot abort the resolution of its siblings. Missing bindings come back as
  `{:warning, %{code: "MISSING_DATA_BINDING", …}}`, once per path per call.
- **Template parsing counts characters.** The 10 000-character limit applies to
  codepoints, not bytes (as in Python, unlike JavaScript's UTF-16 length).

## Processor and validation

- **Envelopes are validated against a permissive catalog.** `Processor.process/2`
  decodes with `catalog: :permissive` (any component object, any theme, a
  well-formed function call), and the processor then checks every component against the
  catalog its surface actually uses. The reference binds the first catalog's schema into
  the envelope check, so a component of a second catalog could only be validated there
  by accident.
- **`allowed_messages` is enforced.** `ValidationConfig.allowed_messages` is declared
  but never read in the Python SDK. The processor rejects other actions with
  `INVALID_ACTION`.
- **Failures are values, with no rollback across operations.** `Processor.process/2`
  returns `{:error, error, processor}`; operations applied before the failing one stay
  applied (as in the reference), and a failing `updateComponents` batch leaves its
  surface untouched.
- **Detail codes follow the conformance corpus for component properties.** A property
  that fails its schema is `missing_field` (required), `extra_field` (surplus) or
  `invalid_value` (everything else). Python's payload validator reports `type`, `enum`,
  `pattern` and `format` failures as `type_mismatch`; the shared suites (asserted by the
  Swift runner) expect `invalid_value`. An unknown component carries
  `unrecognized_component` as in Python plus `invalid_value` at its `component`
  property.
- **Detail paths are located by message.** Failures inside a message list or
  `{"messages": [...]}` wrapper carry `messages.<i>.` in front of the envelope path
  (`messages.0.createSurface.catalogId`), as the Swift SDK does; Python never asserts
  paths. Component-level details keep their `components.<id>.<property>` form, which
  the harness matches by tail (`chartType` is found at `components.c1.chartType`).
- **v0.8 suites are skipped by file name.** A suite ending in `_v0_8.yaml` is out of
  scope even when a case names no version.

## Node resolution and accessibility

- **The resolver is a value, not an observer.** The TypeScript and Dart resolvers are
  reactive: nodes hold signals and notify subscribers. `NodeResolver` is immutable. The
  host hands it the surface after a change (`update/2`) and reads what happened from the
  returned notifications (`{:node_created | :node_updated | :node_destroyed, ref}`).
  One `update/2` is one batch, so a node whose props changed reports once however many
  properties moved. The suite's "last emission equals final props" and "earlier binding
  snapshots stay unchanged" checks hold by construction and are not asserted.
- **Identity is the edge, not the object.** A node keeps its `ref` while the edge that
  leads to it (parent, property slot, component id, data path, occurrence) keeps leading
  to the same kind of node. A placeholder that receives its definition, or a component
  whose type changes, is a new node and the old one is destroyed — the behaviour
  `replaced_nodes` asserts.
- **Diagnostics are edge-triggered.** An unknown type, a cycle or a binding problem is
  reported when it appears and again only after it went away.
- **Literal dynamic properties are read-only bindings.** With `wrap: true` the Binder
  uses the schema's declared properties (including `allOf` envelope members), so a
  literal in a `DynamicString` slot arrives as `%Binding{value: …, path: nil}` like the
  reference's `ResolvedBinding`; without it the Binder keeps inferring from the value's
  shape.
- **Accessibility is checked at the model level only.** No upstream SDK runs
  `accessibility.yaml` (Python skips it, TypeScript has no handler, Swift checks a subset
  of literal attributes). The Elixir handler checks `label`, `description`, `live`,
  `hidden`, `role` and `checked` against `A2UICore.Accessibility`, asserts `{path: …}`
  expectations as bindings, and runs the catalog lint. `assertions.axeCore` names DOM
  rules of a browser renderer; it is ignored here and belongs to the Phoenix renderer's
  tests.
- **Roles and the lint heuristic are ours.** The spec fixes the attributes and the
  explicit-over-inferred rule, not role names or how a linter recognises "accepts
  actions or input bindings". The role map is the four types the suite names; the lint
  treats a property referencing `Action`, or a `value` bound to a `Dynamic*` type, as
  interactive and accepts any of `label`, `title`, `text`, `child` as a labelling
  fallback.

## Function RPC

- **There is no listener and no future.** The Python handler takes an
  `outbound_listener` callback and returns an asyncio future per agent call. `RPC` is a
  value: `call_agent_function/4` returns the `callAgentFunction` message and a pending
  record, and a call is settled by data the host feeds back (`agentFunctionResponse`,
  `timeout/2`, `cancel/3`, `dispose/2`), which returns `{:resolved | :rejected, …}`
  settlements. `NO_LISTENER` therefore never occurs; the timeout of a call is exposed
  (`pending_timeout/2`) for the host to arm a timer.
- **Call ids are counted.** A call without an explicit `functionCallId` gets `call-<n>`
  from a counter in the handler rather than a random UUID, so the handler stays
  deterministic.
- **Functions run synchronously.** An implementation is `(args, context) -> {:ok, value}
  | {:ok, value, effects} | {:error, error}`; there is no awaitable result to wait for.
  A raised exception becomes `EXECUTION_ERROR` as in Python.
- **An omitted `allowedCallers` means `rendererOnly`.** The protocol guide defines the
  default and Python's handler applies it; `A2UICore.Catalog.Function` keeps `nil` for
  "omitted" and the RPC reads it as `rendererOnly`.

## Phoenix renderer

The reference renderers (`typescript/web_core/src/universal/basic_catalog`, used by the
Lit, React and Angular packages) render in the browser. `a2ui_phoenix` renders on the
server with LiveView; the markup and class names follow the reference components.

- **One session per conversation, owned by the LiveView.** `A2UIPhoenix.Session` pairs
  the processor with one `NodeResolver` per surface and re-resolves the surfaces a
  message touched. User input travels from the `A2UIPhoenix.Surface` LiveComponent to
  the LiveView process as a message, so writes and agent messages are applied in arrival
  order.
- **Local UI state lives on the server.** The open tab, whether a modal is open and a
  choice filter are kept in the LiveComponent by node `ref` (the reference keeps them in
  the custom element). A node that is replaced starts with fresh state, as a new element
  would.
- **A modal opens through a trigger that acts.** In the browser the click on a trigger
  button bubbles to the trigger wrapper, so the button's action fires and the modal
  opens. LiveView delivers only the nearest `phx-click`, so an action from a node inside
  a modal's trigger also opens that modal.
- **Body text is plain unless the host renders markdown.** The reference renders body
  text through a markdown renderer. There is no markdown dependency here; the
  `:markdown` assign of `A2UIPhoenix.Surface` takes `(text -> safe HTML)`, and the host
  is responsible for sanitising it.
- **ARIA goes on the component's root element.** As in the reference, `aria-label`
  comes from an explicit `accessibility.label` only (an inferred label is already the
  visible text), `aria-live` is set when it is not `"off"` and `aria-hidden` when true.
  Native controls carry their own roles; a single-choice picker is a `radiogroup`, a
  multiple one a `group`. An icon without a label is `aria-hidden`; inputs point
  `aria-describedby` at their check messages.
- **`openUrl` is executed by the browser.** The catalog function checks the scheme; the
  session turns a successful `openUrl` call into `{:open_url, url}` and
  `A2UIPhoenix.Live` pushes it as the `a2ui:open_url` event, which
  `priv/static/a2ui_phoenix.js` opens in a new tab.
- **A component whose checks fail does not act.** The reference disables the button;
  the session also refuses the action (`COMPONENT_INVALID`).
- **The submitted value is written as the input gives it.** A `TextField` writes the
  string it holds (also for `number`), a `Slider` writes a number, a `CheckBox` a
  boolean, a `ChoicePicker` a list, and a `DateTimeInput` combines its date and time
  inputs with the reference's rules.

## Agent SDK

The reference is the Python agent SDK (`python/a2ui_agent`): its catalog providers,
transformers and resolution, `validate_payload`, and the direct JSON format
(`inference_formats/direct_json`).

- **Parsers are values.** `Parser.parse_chunk/3` returns the next parser along with the
  parts, and a format's `parser/1` returns a fresh one, so two parsers never share state
  (the `parser_state_isolated` cases hold by construction). A response is either wrapped
  or not: a chunk that says otherwise than the first one raises `ArgumentError`.
- **Messages stay JSON maps.** `compile` and `parse_response` return the parsed message
  maps, validated with `A2UIAgent.PayloadValidator`, not typed message models.
- **A lone surrogate escape reads as U+FFFD.** Python strings can hold an unpaired
  surrogate from `\uD83D`; an Elixir string cannot. A surrogate pair cut by the end of a
  streamed chunk still heals before the pair, as in Python.
- **JSON keeps its source's key order.** A prompt writes the protocol schemas in the
  order they are published in and each catalog document in the order it was read in
  (see "Key order comes from ordered input"), so it equals the reference's byte for byte
  (the conformance golden prompts check it). An example message keeps its order when it
  is a `Jason.OrderedObject`; a map is written in Jason's order (sorted for objects of up
  to 32 keys). Non-ASCII characters are written as UTF-8 rather than `\uXXXX` escapes
  (`json.dumps` defaults to `ensure_ascii=True`; the TypeScript and Dart SDKs write
  UTF-8 as well).
- **Pruning messages reads the allowlist once.** `SchemaPruning.prune_messages/2` keeps a
  definition when one of its properties is named in the allowlist. Python also adds
  definitions whose properties name a definition added earlier in its iteration, which
  depends on the document's key order; decoded JSON objects do not keep it.
- **Capabilities are validated by hand.** Python validates renderer capabilities with
  pydantic models; `CatalogResolver` checks the same shape and reports the same
  problems (not a mapping, missing entry, extra keys, ids not a list of strings).
- **v0.8 catalogs are out of scope.** Agent cases that name a v0.8 catalog file are
  skipped (invariant 3).

## Legacy agent suites

`conformance/agent/legacy/` holds the suites of the earlier agent interface. The
blueprint suites replaced some of their rules on purpose. The Python SDK no longer runs
them; the TypeScript SDK runs `parser.yaml` and `inference_format.yaml` and skips the
cases whose rules were replaced.

- **Replaced rules are skipped, with what replaced them.** As in the TypeScript harness,
  catalog selection follows `catalog_resolution.yaml` (every catalog in common, inline
  catalogs alongside) and prompts follow `direct_json/prompt_generator.yaml`. This
  library also follows `direct_json/response_parser.yaml` (a response without tags is
  text, not an error) and Python's blueprint parser (an empty block is reported when it
  is compiled). `streaming_parser.yaml` as a whole is skipped:
  `direct_json/response_streaming.yaml` replaced it, and the TypeScript SDK lists the
  rules that changed (trimmed text, emitting a message as soon as it reads, failing a
  block when it closes). `A2UIConformance.SkipPolicy` gives each skipped case its
  reason, and an entry that matches no case fails the suite.
- **Legacy parsing did not validate.** `parse_full` cases split the response with the
  direct JSON parser's `unwrap/1` and read each block with `A2UIAgent.PayloadFixer`, a
  port of the reference's `parse_and_fix`, as the TypeScript harness does with
  `parseAndFix`.
- **Catalog files without a version load as v0.9,** the legacy default, as the
  TypeScript harness loads them.

## Express

The references are the Python (`python/a2ui_agent/src/a2ui/inference_formats/express`)
and TypeScript (`typescript/agents/a2ui_agent/src/inference-formats/express`)
implementations. Where they differ, the port follows the one the conformance data was
made with.

- **Prompt, decompiler and skills follow Python; compiler and signatures follow
  TypeScript.** The golden prompts and skills (`conformance/test_data/skills`,
  `express_base_rules.txt`, `express_catalog_instructions.txt`) are written by the Python
  SDK, so the prompt generator, the decompiler and the skill generator are ported from it
  (the TypeScript prompt writes `child (component ID)` where the goldens have
  `child (static)`). The compiler and `Express.SchemaHelper` are ported from TypeScript,
  which passes every Express case where Python skips five. `SchemaHelper` reads the
  catalog document as Python does: local and peer `$ref`s inlined, common type refs
  kept, and a local `$ref` met while walking the inlined document not followed again.
- **Catalogs must keep their key order.** Positional arguments follow the order of a
  component's properties in its catalog document. A catalog read from a map lists them by
  name (see "Key order comes from ordered input"), which changes every signature.
- **Default check messages capitalize like Python.** A check without a message gets
  `"<Name> check failed"` with Python's `str.capitalize()` (first letter upper case, the
  rest lower case) in the compiler and the decompiler; TypeScript only raises the first
  letter.
- **Inline component ids.** A component written inline gets the id
  `<parent>_<property>`, or `<parent>_<property>_<index>` with a 0-based index, as in
  TypeScript. An id that collides with a variable, a component id or an id generated
  earlier is a validation error. Generated ids are tracked per surface and per standalone
  call; TypeScript tracks them per compilation.
- **A block that is not final stops at its first syntax error.** The reference parsers
  are generated by ANTLR, which recovers inside a statement. The hand-written parser of
  `Express.Syntax` does not: a block whose closing tag has not arrived compiles the
  statements that start on a line before the first error. A final block with an error is
  a parse error, as in the references.
- **A check rule's first argument is a path only when written as one.** The compiler
  works on the syntax tree, so the component's bound value is passed to a check unless
  its first argument is written `$...`. TypeScript evaluates arguments first and also
  takes a map literal with a `path` key for a path.
- **`_` outside an argument slot** compiles to `{"skipped": true}`, as in TypeScript.
- **Skill frontmatter imitates PyYAML.** `Skill.to_markdown/1` writes plain, single- and
  double-quoted scalars with PyYAML's rules and folds plain and single-quoted scalars at
  80 columns. It covers the names, descriptions and metadata the skills use (the goldens
  match byte for byte), not every scalar PyYAML can write; double-quoted scalars are not
  folded.
- **A streamed Express response is answered once complete.** Python's streaming A2A
  helper calls `parse_chunk` on any parser; the Express parser raises
  `NotImplementedError` there, so each chunk becomes fallback text (or nothing).
  `Express.Parser` has no `parse_chunk/3`, and `A2UIAgent.A2A.Server` buffers the chunks
  for a parser without it, then answers with the parsed response when the output is
  complete, for `message/stream` too.

## Builder and macros

The references are the Python builder (`python/a2ui_agent/src/a2ui/builder`) and macro
transformer (`python/a2ui_agent/src/a2ui/transformers/macros`); no other SDK implements
them (the TypeScript harness skips both suites).

- **One builder for every catalog, driven by the catalog when flattening.** Python
  generates a typed class per component of the v0.9 basic catalog; the classes carry the
  catalog's defaults, and pydantic rejects unknown properties and values when a node is
  made. `A2UIAgent.Builder` makes generic component nodes, and `flatten/2` with
  `:catalog` adds the catalog's defaults and checks each component with the core
  validator, so a component the catalog rejects raises when the tree is flattened. The
  builder writes bindings and function calls for the protocol version; Python's builder
  is v0.9 only.
- **Snake case keys are camelized.** Python fields are snake case with aliases for the
  wire names. Atom keys are written in lower camel case; string keys as given.
- **No object identity.** Python emits a node object placed in two slots once and
  references it twice. Elixir values have no identity: a subtree placed twice is emitted
  twice, with different made ids.
- **Children follow the catalog's property order.** Python emits children in the
  generated class's field order. With `:catalog` the builder follows the catalog
  document's order, which is the same for a component's own properties; without one, the
  order the properties were given in.
- **Macro parameters are declared.** Python reads a macro's parameters, their schemas and
  descriptions from the function's type hints and docstring. An Elixir function has
  neither, so `Macro.new/4` takes the parameter types (named after the conformance
  suite's: `:dynamic_string`, `:component_list`, ...) and descriptions. A missing
  description is the name, spaced and capitalized, as in Python.
- **Macros compose through call nodes.** A Python macro calls another as a function,
  inline, and a cycle ends at the interpreter's recursion limit. `Macro.call/2` puts a
  call in the tree, expanded when the tree is flattened, in its scope (so the made ids are
  Python's); calls nested deeper than 16 fail with a recursion error, the limit Python's
  expander applies to nested expansions.
- **The expander knows its base catalog.** Python's `MacroExpander` is given the base
  catalog by `transform_to_inference_catalog`, and expansions need none because the
  generated classes carry the defaults. `MacroExpander.new/3` takes the base catalog for
  both: the inference catalog is built from it, and expansions are completed and checked
  against it. An expansion the catalog rejects leaves its macro component in place, with
  the failure logged, as any failing macro does in Python.
- **The standalone macro catalog follows the base catalog's version.** Python's
  `to_catalog` always writes protocol 0.9.1; `macro_catalog/1` uses the base catalog's
  version, whose common types the macro schemas refer to.
- **The harness writes the suite's macros in Elixir.** The reference harness defines them
  in Python, and the YAML templates are sketches that differ from the goldens
  (`StatusBadge` upper-cases its status, `ConfigCard` writes `True`). The conformance
  handler defines the same macros with the builder and the YAML's parameter types;
  `ConfigCard` formats its arguments with Python's `str()`.

## Transports

The references are the Python A2A helpers (`python/a2ui_agent/src/a2ui/a2a`), the
Kotlin legacy `A2aHandler` (which the conformance harness drives for `handle_rpc`), the
Node sample agent (`samples/agent/node/restaurant_finder`, the A2A server with tests)
and the sample web clients.

- **One A2UI message per data part.** Both extension specifications say a data part's
  `data` "MUST be an array of messages". The Python, Kotlin and Node SDKs and samples all
  send one message per part, the sample clients read `part.data` as one message, and in
  A2A's JSON-RPC binding a `DataPart`'s `data` is an object. `A2UIAgent.A2A` writes one
  message per part; `a2ui_messages/1` reads either shape.
- **`message/send` answers with a task.** The Kotlin handler answers with a message
  (`result.parts`); the Node sample agent answers with a task whose status message holds
  the parts, which is what the sample clients read. `A2UIAgent.A2A.Server` answers with
  a task, so the conformance handler reads the parts from its status message.
- **The MIME type of a part follows its version.** Python marks a part
  `application/json+a2ui` when its version is unknown or is one of "0.8", "0.9", "v0.8"
  and "v0.9", and `application/a2ui+json` otherwise. `A2A.mime_type/1` uses the older
  type when the version is unknown or reads as a version before v0.9.1, which agrees with
  Python on every version Python lists.
- **A request without capabilities is answered in text.** The Node sample falls back to
  its default protocol version and basic catalog. `A2UIAgent.A2A.Server` negotiates only
  with capabilities the message carries or that the `:default_capabilities` option
  gives; without either, the agent gets no processor and its output is sent as text.
- **A stream that stops parsing fails the task.** Python's `parse_stream_chunk_to_parts`
  logs the error, adds its fallback text and goes on with the same parser. A direct JSON
  parser that fails returns no parser to go on with, so the stream ends with a `failed`
  status update. A complete response that does not parse is still answered with its
  text, as in Python.
- **Streamed messages can repeat.** The streaming parser emits a message again each time
  it grows (as Python's does), so a `working` update can carry a newer copy of a message
  an earlier update carried. Each copy is a whole, valid message.
- **The A2A plug's events carry data only.** `A2UIPhoenix.Plug.SSE` writes `id:` and
  `retry:` fields when asked and reads `Last-Event-ID`; the A2A plug writes `data:` lines
  only, since A2A resumes a task with `tasks/resubscribe`, which it does not implement.
- **MCP follows the A2UI guide; AG-UI follows AG-UI's middleware.** Neither binding has
  a normative A2UI specification. `A2UIAgent.MCP` builds what the guide "A2UI over MCP"
  shows (resources and embedded resources with `application/a2ui+json`, `_meta.ui`
  links, `capabilities.a2ui.clientCapabilities` in `initialize` or a tool call's
  `_meta`, the `a2ui_action` and `a2ui_error` tools); it is not an MCP server.
  `A2UIAgent.AGUI` follows the conventions of AG-UI's `a2ui-middleware`: activity
  snapshots of type `a2ui-surface` with the messages under `a2ui_operations`, and user
  actions in `forwardedProps.a2uiAction.userAction`. A snapshot replaces its activity,
  so each one carries all its surface's messages so far. The middleware's tool
  injection, recovery and lifecycle snapshots belong to AG-UI's side and are not ported.
- **No WebSocket binding.** A2UI names WebSockets as a possible transport but defines no
  framing or metadata for one. Inside Phoenix, LiveView (`A2UIPhoenix.Live`) already
  carries the renderer's two-way traffic over its socket.
- **The MCP catalog is not implemented.** `catalogs/mcp` (`callMcpTool`, the `McpApp`
  component and, for v0.9, data functions such as `jmespath`) is an optional catalog
  that only the TypeScript SDK implements; it needs an MCP client in the renderer, a
  JMESPath evaluator and the MCP Apps iframe bridge.
- **ADK integration is out of scope.** The `extensions/adk` cases (`convert_event`,
  `execute_tool`, ADK's `data_model` and `resolve_path`) test adapters to Google's Python
  Agent Development Kit, which has no Elixir runtime; they are skipped as an optional
  family.

defmodule Site.Content do
  @moduledoc """
  What the landing page says, as data: the packages, the features by area,
  the catalogs, the transports, the conformance results, the examples and
  the code samples. The template only lays it out.

  The figures are those of the repository at the pinned specification
  commit (`SPEC_PIN`); the conformance table is the README's.
  """

  @spec_commit "5d74ffb"
  @repo_url "https://github.com/a2ui-elixir/a2ui"
  @site_url "https://a2ui-elixir.github.io/a2ui/"
  @video_id "16X-sRsGlcs"

  @doc "The upstream commit the conformance figures were measured at."
  def spec_commit, do: @spec_commit

  @doc "The project's repository."
  def repo_url, do: @repo_url

  @doc "Where the page is published (GitHub Pages)."
  def site_url, do: @site_url

  @doc "The social preview image, by its absolute URL (`priv/static/social.png`)."
  def social_image_url, do: @site_url <> "social.png"

  @doc "The video, a minute long, on YouTube."
  def video_url, do: "https://www.youtube.com/watch?v=" <> @video_id

  @doc "The video's player, played where the page's poster was (YouTube's no-cookie host)."
  def video_embed_url, do: "https://www.youtube-nocookie.com/embed/#{@video_id}?autoplay=1&rel=0"

  @doc "The video's length, as the page shows it."
  def video_duration, do: "1:03"

  @doc "A package's page on Hex."
  def hex_url(package), do: "https://hex.pm/packages/" <> package

  @doc "A package's documentation on HexDocs."
  def docs_url(package), do: "https://hexdocs.pm/" <> package

  @doc "A page of a package's documentation on HexDocs."
  def docs_url(package, page), do: docs_url(package) <> "/" <> page

  @doc "The protocol versions the packages implement."
  def versions, do: ["v0.9", "v0.9.1", "v1.0"]

  @doc """
  The headline figures. `bar` is the share to draw, in percent, and `mark`
  a threshold drawn on the bar.
  """
  def stats do
    [
      %{
        key: "Conformance",
        value: "946/946",
        label: "upstream cases that run, all passing",
        bar: 100
      },
      %{
        key: "Protocol",
        value: "v0.9 → v1.0",
        label: "v0.9, v0.9.1 and v1.0 on one engine",
        bar: nil
      },
      %{
        key: "JSON Schema",
        value: "1302/1302",
        label: "required tests of draft 2020-12",
        bar: 100
      },
      %{key: "JMESPath", value: "892/892", label: "compliance tests", bar: 100},
      %{key: "Catalog", value: "18 + 14", label: "basic components and functions", bar: nil},
      %{
        key: "Coverage",
        value: "97.8%",
        label: "lines covered, behind a 95% gate",
        bar: 97.8,
        mark: 95
      }
    ]
  end

  @doc "The protocols and standards the packages speak."
  def standards do
    [
      %{name: "A2UI", note: "v0.9 · v0.9.1 · v1.0"},
      %{name: "A2A", note: "JSON-RPC · streaming"},
      %{name: "MCP", note: "tools · resources · apps"},
      %{name: "AG-UI", note: "activity snapshots"},
      %{name: "SSE", note: "Last-Event-ID"},
      %{name: "WebSocket", note: "example agent"},
      %{name: "LiveView", note: "phoenix_live_view 1.2"},
      %{name: "JSON Schema", note: "draft 2020-12"}
    ]
  end

  @doc "The three packages, and the conformance harness."
  def packages do
    [
      %{
        name: "a2ui_core",
        namespace: "A2UICore",
        dep: ~s({:a2ui_core, "~> 0.1.0"}),
        role: "Protocol engine",
        icon: "core",
        modules:
          ~w(Processor Message Schema Catalog State.DataModel Expression Resolution.NodeResolver RPC),
        summary:
          "Messages, schemas, catalogs, surface state, expressions, node resolution and function calls. Pure Elixir: no processes, Jason its only dependency.",
        points: [
          "Version adapters for v0.9, v0.9.1 and v1.0",
          "A JSON Schema 2020-12 engine for messages and catalogs",
          "A processor that returns effects as data",
          "The resolved component tree a renderer draws",
          "Function calls between renderer and agent"
        ]
      },
      %{
        name: "a2ui_phoenix",
        namespace: "A2UIPhoenix",
        dep: ~s({:a2ui_phoenix, "~> 0.1.0"}),
        role: "LiveView renderer",
        icon: "render",
        modules: ~w(Session Live Surface Components.Basic MCPApp Plug.SSE),
        summary:
          "Draws A2UI surfaces in Phoenix LiveView: the basic catalog as function components, two-way bindings, actions, MCP Apps, and a server-sent events plug.",
        points: [
          "A session that is plain data, owned by your LiveView",
          "18 components with ARIA attributes and a themable stylesheet",
          "Your own components, by type",
          "Agent function calls with busy states and timeouts",
          "Sandboxed MCP Apps and their bridge"
        ]
      },
      %{
        name: "a2ui_agent",
        namespace: "A2UIAgent",
        dep: ~s({:a2ui_agent, "~> 0.1.0"}),
        role: "Agent SDK",
        icon: "agent",
        modules:
          ~w(Generator RequestProcessor DirectJson.Parser Express Builder A2A.Plug MCP AGUI),
        summary:
          "Negotiates catalogs with each renderer, writes the model's prompt, and reads the model's output back as validated messages, whole or while it streams.",
        points: [
          "Catalog negotiation from the renderer's capabilities",
          "Prompts in the direct JSON and Express formats",
          "A streaming parser that emits messages as they complete",
          "A component builder and macros",
          "An A2A server and plug, with MCP and AG-UI helpers"
        ]
      }
    ]
  end

  @doc "The harness that keeps the packages honest."
  def harness do
    %{
      name: "a2ui_conformance",
      summary:
        "Runs the upstream YAML conformance suites, core, agent and extensions, against all three packages at a pinned commit of the specification."
    }
  end

  @doc "A turn, from the renderer's capabilities to the user's action."
  def lifecycle do
    [
      %{
        side: "agent",
        title: "Negotiate",
        text: "The renderer's capabilities choose the catalogs both sides hold.",
        module: "A2UIAgent.Generator"
      },
      %{
        side: "agent",
        title: "Prompt",
        text: "The chosen catalogs' schemas go into the model's system prompt.",
        module: "A2UIAgent.RequestProcessor"
      },
      %{
        side: "agent",
        title: "Stream",
        text: "The model's output is read chunk by chunk; each message leaves as it completes.",
        module: "A2UIAgent.DirectJson.Parser"
      },
      %{
        side: "agent",
        title: "Validate",
        text: "Every message is checked against the protocol's schemas and the catalogs.",
        module: "A2UIAgent.PayloadValidator"
      },
      %{
        side: "renderer",
        title: "Render",
        text: "The processor applies each message, and LiveView draws the surfaces.",
        module: "A2UIPhoenix.Surface"
      },
      %{
        side: "renderer",
        title: "Respond",
        text: "Actions, errors and function calls go back to the agent.",
        module: "A2UIPhoenix.Live"
      }
    ]
  end

  @doc "The protocol's messages: who sends each, and the first version that has it."
  def messages do
    [
      %{name: "createSurface", from: "agent", since: "v0.9"},
      %{name: "updateComponents", from: "agent", since: "v0.9"},
      %{name: "updateDataModel", from: "agent", since: "v0.9"},
      %{name: "deleteSurface", from: "agent", since: "v0.9"},
      %{name: "callRendererFunction", from: "agent", since: "v1.0"},
      %{name: "agentFunctionResponse", from: "agent", since: "v1.0"},
      %{name: "action", from: "renderer", since: "v0.9"},
      %{name: "error", from: "renderer", since: "v0.9"},
      %{name: "callAgentFunction", from: "renderer", since: "v1.0"},
      %{name: "rendererFunctionResponse", from: "renderer", since: "v1.0"}
    ]
  end

  @doc "Dynamic values, and what they resolve to against the hero's data model."
  def bindings do
    [
      %{value: ~s({"@path": "/booking/name"}), result: ~s("Ada")},
      %{
        value: ~s({"@call": "formatString", "args": {"value": "Hi ${/booking/name}"}}),
        result: ~s("Hi Ada")
      },
      %{
        value: ~s("children": {"path": "/places", "componentId": "card"}),
        result: "a card per place"
      }
    ]
  end

  @doc "The function calls between renderer and agent (v1.0)."
  def rpc do
    [
      %{name: "callAgentFunction", to: "agent"},
      %{name: "agentFunctionResponse", to: "renderer"},
      %{name: "callRendererFunction", to: "renderer"},
      %{name: "rendererFunctionResponse", to: "agent"}
    ]
  end

  @doc """
  A response streamed in three chunks, and what
  `A2UIAgent.DirectJson.Parser.parse_chunk/3` emits for each.
  """
  def stream do
    [
      %{
        chunk:
          ~s(Here are two places. <a2ui-json>[{"version": "v1.0", "createSurface": {…}}, {"version": "v1.0", "updateCompo),
        parts: ["text", "createSurface"]
      },
      %{
        chunk: ~s(nents": {"surfaceId": "list", "components": […]}}),
        parts: ["updateComponents"]
      },
      %{
        chunk: ~s(, {"version": "v1.0", "updateDataModel": {…}}]</a2ui-json> Want to book?),
        parts: ["updateDataModel", "text"]
      }
    ]
  end

  @doc "A component the strict renderer rejects, and the error it reports to the agent."
  def error_example do
    %{
      sent: ~S"""
      {"version": "v1.0", "updateComponents": {
        "surfaceId": "booking", "components": [
          {"id": "title", "component": "Text",
           "text": "Hi", "variant": "h2"}]}}
      """,
      reported: ~S"""
      {"version": "v1.0", "error": {
        "code": "VALIDATION_FAILED",
        "surfaceId": "booking",
        "path": "/components/0/variant",
        "message": "Validation failed for component 'Text': components.title.variant: 'h2' is not one of [\"caption\", \"body\"]"}}
      """
    }
  end

  @doc "Every feature, by area."
  def feature_groups do
    [
      %{
        id: "protocol",
        span: 2,
        visual: "messages",
        title: "Protocol and messages",
        icon: "protocol",
        packages: ["core"],
        items: [
          "Message adapters for v0.9, v0.9.1 and v1.0: decoded into version-neutral operations and encoded back",
          "Every message checked against the specification's JSON schemas",
          "`createSurface`, `updateComponents`, `updateDataModel` and `deleteSurface`, with v1.0 inline components and data",
          "Renderer-to-agent messages: `action` (with `userMessage`), `error`, `callAgentFunction`, `rendererFunctionResponse`",
          "Renderer capabilities and data models for the transport's metadata",
          "v1.0 reserved `@` keys, and `@@` escaping for literal ones"
        ]
      },
      %{
        id: "data",
        span: 1,
        visual: "bindings",
        title: "Data binding and expressions",
        icon: "data",
        packages: ["core"],
        items: [
          "A data model addressed by JSON Pointer, with change notifications",
          "Two-way bindings, list templates with relative paths, and `@index`",
          "`${…}` templates in `formatString`, with nested function calls",
          "Numbers, currencies, TR35 dates and plurals, behind a pluggable formatter",
          "Checks with `required`, `regex`, `length`, `numeric`, `email`, `and`, `or` and `not`; `ValidationResult` in v1.0"
        ]
      },
      %{
        id: "catalogs",
        span: 1,
        visual: "catalog",
        title: "Catalogs and components",
        icon: "catalog",
        packages: ["core", "phoenix"],
        items: [
          "The basic catalog of each version: 18 components and 14 functions, implemented",
          "Catalogs of your own: read, validated, and written back in their key order",
          "`catalogId` per component and per function call: several catalogs on one surface (v1.0)",
          "Composition constraints: `allowedParents` and `allowedChildren`",
          "Inline catalogs, announced in the renderer's capabilities",
          "Catalog names checked as UAX #31 identifiers"
        ]
      },
      %{
        id: "rendering",
        span: 1,
        visual: "tree",
        title: "Rendering in LiveView",
        icon: "render",
        packages: ["phoenix"],
        items: [
          "Surfaces as LiveComponents over a session that is plain data",
          "The 18 basic components as function components, with ARIA attributes",
          "Actions, two-way bindings and local UI state such as tabs and modals",
          "Placeholders for children still streaming, and stable node identity",
          "Your own components by type, and Markdown through the renderer you choose",
          "v0.9 surface themes, and a stylesheet driven by CSS custom properties"
        ]
      },
      %{
        id: "rpc",
        span: 1,
        visual: "rpc",
        title: "Functions and RPC",
        icon: "rpc",
        packages: ["core", "phoenix"],
        items: [
          "`callRendererFunction` answered with `rendererFunctionResponse`, under `allowedCallers` and `requiresUserActivation`",
          "Calls a surface cannot run sent to the agent as `callAgentFunction`, with busy states and timeouts",
          "Function-call actions, and `openUrl` restricted to http and https",
          "RPC as a pure state machine: timeouts are events the host feeds in",
          "Functions reserved for the agent, or needing a user gesture, refused inside the renderer"
        ]
      },
      %{
        id: "agent",
        span: 2,
        visual: "stream",
        title: "Agent SDK",
        icon: "agent",
        packages: ["agent"],
        items: [
          "Catalog negotiation from the renderer's capabilities, inline catalogs included",
          "Catalog transformers that prune components and functions",
          "Prompts written byte for byte as the reference SDKs write them",
          "A streaming parser that emits each message as it completes, and reads near-JSON",
          "Express: a compact notation, its compiler and decompiler, and skills",
          "A component builder in Elixir, and macros the model expands into catalog components"
        ]
      },
      %{
        id: "transports",
        span: 1,
        title: "Transports",
        icon: "transport",
        packages: ["agent", "phoenix"],
        items: [
          "A2A JSON-RPC: `message/send` and `message/stream`, extension negotiation, and a Plug",
          "MCP: A2UI messages in tool results and resources",
          "AG-UI: activity snapshots, events and user actions",
          "Server-sent events with event ids and `Last-Event-ID` resumption",
          "WebSocket, shown in the example agent"
        ]
      },
      %{
        id: "mcp",
        span: 1,
        title: "MCP tools and apps",
        icon: "mcp",
        packages: ["core", "phoenix"],
        items: [
          "`callMcpTool` through your MCP client, with `targetDataPath`",
          "`McpApp`: MCP Apps in a double-iframe sandbox under a Content Security Policy",
          "The app bridge: `data.paths`, `allowedTools`, `allowedFunctions`, model context and messages",
          "A complete JMESPath, with `split`, `regexCapture`, `regexReplace` and `updateDataModel`"
        ]
      },
      %{
        id: "validation",
        span: 2,
        visual: "error",
        title: "Validation and resilience",
        icon: "shield",
        packages: ["core", "phoenix"],
        items: [
          "Strict validation, and a relaxed mode for surfaces that are still streaming",
          "Integrity checks: missing root, dangling references, cycles, orphans, depth limit",
          "Errors as values, reported to the agent with a JSON Pointer to the field",
          "Accessibility checks, and `aria-busy` on components waiting for the agent",
          "JSON Schema draft 2020-12 with ECMA-262 regular expressions"
        ]
      }
    ]
  end

  @doc "The MCP catalog of each version."
  def mcp_catalogs do
    [
      %{version: "v1.0", components: ["McpApp"], functions: ["callMcpTool"]},
      %{
        version: "v0.9",
        components: [],
        functions: ~w(callMcpTool jmespath split regexCapture regexReplace updateDataModel)
      }
    ]
  end

  @doc "The basic catalog's components, by kind."
  def components do
    [
      {"Content", ~w(Text Image Icon Video AudioPlayer)},
      {"Layout", ~w(Row Column List Card Tabs Modal Divider)},
      {"Input", ~w(Button TextField CheckBox ChoicePicker Slider DateTimeInput)}
    ]
  end

  @doc "The basic catalog's functions, by kind."
  def functions do
    [
      {"Checks", ~w(required regex length numeric email)},
      {"Formatting", ~w(formatString formatNumber formatCurrency formatDate pluralize)},
      {"Logic", ~w(and or not)},
      {"Actions", ~w(openUrl)}
    ]
  end

  @doc "How agent and renderer talk."
  def transports do
    [
      %{
        name: "A2A",
        detail:
          "`message/send` answers with the finished task, `message/stream` with server-sent events as the model writes. The A2UI extension is negotiated per request; capabilities ride in the message metadata.",
        where: "A2UIAgent.A2A.Plug"
      },
      %{
        name: "MCP",
        detail:
          "Layouts as `application/a2ui+json` resources, data in tool results, linked with `_meta.ui`. Actions and errors come back as calls of the `a2ui_action` and `a2ui_error` tools.",
        where: "A2UIAgent.MCP"
      },
      %{
        name: "AG-UI",
        detail:
          "Each surface as `ACTIVITY_SNAPSHOT` events of the `a2ui-surface` activity; a user's action starts a run, under `forwardedProps.a2uiAction`.",
        where: "A2UIAgent.AGUI"
      },
      %{
        name: "SSE",
        detail:
          "One message per event, with event ids, resumable with `Last-Event-ID`, for renderers outside LiveView.",
        where: "A2UIPhoenix.Plug.SSE"
      },
      %{
        name: "WebSocket",
        detail: "JSON frames in both directions, as the example agent serves them.",
        where: "examples/restaurant_agent"
      }
    ]
  end

  @doc "The inference formats a model writes, each with a sample of what it writes."
  def formats do
    [
      %{
        name: "Direct JSON",
        label: "json",
        detail:
          "Message lists between `<a2ui-json>` tags, read leniently and chunk by chunk, so surfaces build while the model writes.",
        sample: ~S"""
        <a2ui-json>
        [{"version": "v1.0", "createSurface": {
            "surfaceId": "form", "catalogId": "…"}},
         {"version": "v1.0", "updateComponents": {
            "surfaceId": "form", "components": [
              {"id": "root", "component": "Column",
               "children": ["name", "send"]},
              {"id": "name", "component": "TextField",
               "label": "Name", "value": {"@path": "/name"}},
              …]}}]
        </a2ui-json>
        """
      },
      %{
        name: "Express",
        label: "express",
        detail:
          "A compact notation between `<a2ui>` tags, compiled into validated messages and decompiled back for the model's history.",
        sample: ~S"""
        <a2ui>
        surface("form")
        root = Column([name, send])
        name = TextField("Name", $/name)
        send = Button(Text("Send"), action=Event("send", {name: $/name}))
        </a2ui>
        """
      }
    ]
  end

  @doc "The upstream suites, as run at the pinned commit."
  def suites do
    [
      %{name: "core", total: 572, run: 533, skipped: "39 for protocol v0.8"},
      %{name: "agent (shared)", total: 107, run: 107, skipped: nil},
      %{name: "agent/direct_json", total: 163, run: 124, skipped: "39 for v0.8 catalogs"},
      %{name: "agent/express", total: 115, run: 115, skipped: nil},
      %{name: "agent/builder", total: 11, run: 11, skipped: nil},
      %{name: "agent/macros", total: 18, run: 18, skipped: nil},
      %{
        name: "agent/legacy",
        total: 133,
        run: 25,
        skipped: "67 replaced by the blueprint suites, 39 for v0.8, 2 in other formats"
      },
      %{name: "extensions/a2a", total: 14, run: 13, skipped: "1 v0.8 payload"},
      %{name: "extensions/adk", total: 11, run: 0, skipped: "adapters for Google's Python ADK"}
    ]
  end

  @doc """
  Why the skipped cases are skipped: how many, the reason, and the suites
  they come from.
  """
  def skip_reasons do
    [
      %{
        count: 118,
        title: "Protocol v0.8.",
        detail: "The older wire format. The packages implement v0.9, v0.9.1 and v1.0.",
        suites: ["core", "agent/direct_json", "agent/legacy", "extensions/a2a"]
      },
      %{
        count: 67,
        title: "Superseded rules.",
        detail:
          "Cases of the earlier agent interface whose rules the blueprint suites replaced. The Python SDK no longer runs them and the TypeScript SDK skips them too.",
        suites: ["agent/legacy"]
      },
      %{
        count: 11,
        title: "Google's Python ADK.",
        detail: "Adapters to the Python Agent Development Kit, which has no Elixir runtime.",
        suites: ["extensions/adk"]
      },
      %{
        count: 2,
        title: "Elemental and Atom.",
        detail: "Two other inference formats. The packages implement direct JSON and Express.",
        suites: ["agent/legacy"]
      }
    ]
  end

  @doc "What every change has to pass, in order: a short name and the command or check."
  def gates do
    [
      {"format", "`mix format --check-formatted`"},
      {"compile", "`mix compile --warnings-as-errors`"},
      {"credo", "`mix credo --strict`"},
      {"dialyzer", "`mix dialyzer`"},
      {"coverage", "`mix coveralls --umbrella`, 95% minimum"},
      {"conformance", "The upstream suites, at a pinned commit"},
      {"browser", "The renderer's script and sandbox, under Node"},
      {"docs", "`mix docs --warnings-as-errors`; guides whose examples run"}
    ]
  end

  @doc "What else the packages are tested against."
  def corpora do
    [
      "The JSON Schema Test Suite, draft 2020-12: all 1302 required tests",
      "The JMESPath compliance suite: all 892 tests",
      "The 86 upstream example bundles: decoded, encoded back, validated and rendered in LiveView",
      "Property tests for JSON Pointer and the data model"
    ]
  end

  @doc "The example applications."
  def examples do
    [
      %{
        name: "Restaurant agent",
        covers: ~w(A2A MCP AG-UI SSE WebSocket Express v0.9),
        path: "examples/restaurant_agent",
        icon: "agent",
        summary:
          "Finds restaurants and books tables with A2UI surfaces, over A2A, MCP, AG-UI, server-sent events and WebSocket. Agent functions, renderer functions, Express and v0.9 included.",
        run: """
        cd examples/restaurant_agent
        mix deps.get
        mix run --no-halt     # http://127.0.0.1:4001
        """
      },
      %{
        name: "Gallery",
        covers: ["10 scenarios", "43 examples", "chat over A2A", "LiveDashboard"],
        path: "examples/gallery",
        icon: "sparkle",
        summary:
          "A LiveView app with ten scenarios that cover the protocol, the 43 upstream example surfaces, a live chat with the agent, and LiveDashboard metrics.",
        run: """
        cd examples/gallery
        mix deps.get
        mix phx.server        # http://localhost:4000
        """
      },
      %{
        name: "Terminal client",
        covers: ["a2ui_core only", "6 transports", "v1.0 and v0.9"],
        path: "examples/terminal_client",
        icon: "terminal",
        summary:
          "A renderer that draws surfaces as text, on a2ui_core alone, with a client for every transport the agent serves.",
        run: ~S"""
        cd examples/terminal_client
        mix deps.get
        mix chat "Find Italian restaurants"
        """
      }
    ]
  end

  @doc "The gallery's scenarios, with what each shows."
  def scenarios do
    [
      {"Component gallery", "All 18 components, their variants and accessibility attributes"},
      {"Forms and validation",
       "Checks on every input, `sendDataModel`, a form swapped for a summary"},
      {"Data binding", "Templates, relative paths, `@index`, formatting, live updates"},
      {"Surfaces", "Surfaces opened and closed, components replaced, `userMessage`, `openUrl`"},
      {"Functions and RPC", "Calls both ways, with answers, errors, timeouts and refusals"},
      {"Custom catalogs", "Components and functions of the gallery's own catalog"},
      {"Streaming", "A surface built while the model's text arrives, and Express"},
      {"MCP tools and apps", "`callMcpTool`, A2UI in tool results, a sandboxed MCP App"},
      {"Errors and recovery", "Faulty messages: rejected, reported and recovered from"},
      {"Protocol v0.9", "The v0.9 wire format on the same renderer, with its theme"}
    ]
  end

  @doc "The message the hero shows, as an agent sends it (valid v1.0, the catalog id shortened)."
  def hero_message do
    ~S"""
    {
      "version": "v1.0",
      "createSurface": {
        "surfaceId": "booking",
        "catalogId": "https://a2ui.org/…/basic/catalog.json",
        "components": [
          { "id": "root", "component": "Card", "child": "form" },
          { "id": "form", "component": "Column",
            "children": ["title", "name", "when", "book"] },
          { "id": "title", "component": "Text",
            "text": "## Trattoria Roma" },
          { "id": "name", "component": "TextField", "label": "Your name",
            "value": { "@path": "/booking/name" } },
          { "id": "when", "component": "DateTimeInput", "label": "When",
            "value": { "@path": "/booking/date" } },
          { "id": "book", "component": "Button", "child": "go",
            "action": { "event": { "name": "book", "context": {
              "name": { "@path": "/booking/name" },
              "date": { "@path": "/booking/date" } } } } },
          { "id": "go", "component": "Text", "text": "Book a table" }
        ],
        "dataModel": {
          "booking": { "name": "Ada", "date": "2026-10-17T19:30" }
        }
      }
    }
    """
  end

  @doc "The code samples, by tab."
  def samples do
    [
      %{
        id: "render",
        label: "Render in LiveView",
        file: "lib/my_app_web/live/agent_live.ex",
        language: :elixir,
        code: ~S'''
        defmodule MyAppWeb.AgentLive do
          use MyAppWeb, :live_view

          alias A2UIPhoenix.{Live, Session}

          def mount(_params, _session, socket) do
            # Every component checked against its catalog, as it streams in.
            validation = A2UICore.Validation.Config.relaxed()
            catalogs = [A2UICore.Catalog.Basic.catalog("v1.0")]
            session = Session.new(catalogs, validation: validation)
            {:ok, Live.init(socket, session, on_send: &send_to_agent/2)}
          end

          # Messages from the agent, however they arrive.
          def handle_info({:agent, payload}, socket) do
            {_result, socket} = Live.handle_message(socket, payload)
            {:noreply, socket}
          end

          def render(assigns) do
            ~H"""
            <.live_component
              :for={surface <- Session.surfaces(@a2ui)}
              module={A2UIPhoenix.Surface}
              id={"surface-" <> surface.id}
              session={@a2ui}
              surface_id={surface.id}
            />
            """
          end

          # Actions, errors and function calls, for the agent.
          defp send_to_agent(message, socket) do
            Phoenix.PubSub.broadcast(MyApp.PubSub, "a2ui:renderer", {:renderer, self(), message})
            socket
          end
        end
        '''
      },
      %{
        id: "agent",
        label: "Serve an agent",
        file: "lib/my_agent.ex",
        language: :elixir,
        code: ~S'''
        defmodule MyAgent do
          @behaviour A2UIAgent.A2A.Agent

          alias A2UIAgent.A2A.Request

          # No catalog negotiated: answer in text.
          @impl true
          def run(%Request{processor: nil, text: text}), do: {:ok, MyModel.reply(text)}

          # The renderer's capabilities chose the catalogs; the prompt holds their schemas.
          def run(%Request{processor: processor, text: text, events: events}) do
            {:ok, prompt} = A2UIAgent.RequestProcessor.prompt(processor)
            # A string, or the chunks as the model streams them.
            {:ok, MyModel.stream(prompt, text, events)}
          end

          @impl true
          def options do
            basic = A2UIAgent.CatalogConfig.new(A2UICore.Catalog.Basic.catalog("v1.0"))
            [generator: A2UIAgent.Generator.new([basic])]
          end

          @impl true
          def card do
            %{"name" => "My agent", "capabilities" => %{"extensions" => [A2UIAgent.A2A.agent_extension("1.0")]}}
          end
        end

        # In a Phoenix router or a Plug.Router:
        forward "/a2a", A2UIAgent.A2A.Plug, agent: MyAgent
        '''
      },
      %{
        id: "core",
        label: "Process messages",
        file: "iex",
        language: :elixir,
        code: ~S'''
        alias A2UICore.{Processor, Validation}

        catalog = A2UICore.Catalog.Basic.catalog("v1.0")
        processor = Processor.new([catalog], validation: Validation.Config.strict())

        {:ok, processor, effects} =
          Processor.process(processor, [
            %{"version" => "v1.0",
              "createSurface" => %{"surfaceId" => "main", "catalogId" => catalog.catalog_id}},
            %{"version" => "v1.0",
              "updateComponents" => %{
                "surfaceId" => "main",
                "components" => [
                  %{"id" => "root", "component" => "Column", "children" => ["greeting"]},
                  %{"id" => "greeting", "component" => "Text", "text" => %{"@path" => "/name"}}
                ]}},
            %{"version" => "v1.0",
              "updateDataModel" => %{"surfaceId" => "main", "path" => "/name", "value" => "Ada"}}
          ])

        effects
        #=> [{:surface_created, "main"}, {:components_updated, "main", ["root", "greeting"]},
        #    {:data_model_updated, "main", "/name"}]
        '''
      }
    ]
  end

  @doc "Each package's guide, what it covers, and where it is published."
  def guides do
    [
      %{
        package: "a2ui_core",
        path: "guides/processing_messages.md",
        title: "Processing messages",
        covers:
          "catalogs and versions, applying messages, drawing a surface, user input, function calls"
      },
      %{
        package: "a2ui_phoenix",
        path: "guides/rendering_surfaces.md",
        title: "Rendering surfaces",
        covers: "the session, LiveView, agent functions, themes, MCP apps, components of your own"
      },
      %{
        package: "a2ui_agent",
        path: "guides/serving_an_agent.md",
        title: "Serving an agent",
        covers: "catalogs, the prompt, reading the model's output, A2A, MCP and AG-UI, Express"
      }
    ]
    |> Enum.map(
      &Map.put(&1, :url, docs_url(&1.package, Path.basename(&1.path, ".md") <> ".html"))
    )
  end

  @doc "How to get the examples and run the gallery, from a fresh clone."
  def try_it do
    """
    git clone #{@repo_url}.git
    cd a2ui/examples/gallery
    mix deps.get
    mix phx.server        # http://localhost:4000
    """
  end

  @doc "What the packages need."
  def requirements do
    [
      {"elixir", ">= 1.17"},
      {"jason", "the core's only dependency"},
      {"phoenix_live_view", "~> 1.2, for the renderer"},
      {"plug", "optional, for the A2A plug"}
    ]
  end

  @doc "The dependencies a Phoenix app adds."
  def install do
    ~S"""
    def deps do
      [
        # The renderer, with a2ui_core
        {:a2ui_phoenix, "~> 0.1.0"},
        # The agent SDK
        {:a2ui_agent, "~> 0.1.0"}
      ]
    end
    """
  end

  @doc "Links to the repository and to each package's documentation."
  def project_links do
    [%{label: "GitHub", url: @repo_url}] ++
      for name <- ~w(a2ui_core a2ui_phoenix a2ui_agent),
          do: %{label: name, url: docs_url(name)}
  end

  @doc "Links to the protocols the packages implement."
  def links do
    [
      %{label: "A2UI protocol", url: "https://a2ui.org"},
      %{label: "A2A", url: "https://a2a-protocol.org"},
      %{label: "Model Context Protocol", url: "https://modelcontextprotocol.io"},
      %{label: "AG-UI", url: "https://docs.ag-ui.com"}
    ]
  end
end

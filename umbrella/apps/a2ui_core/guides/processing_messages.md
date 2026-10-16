# Processing messages

This guide follows `a2ui_core` from the renderer's side: loading catalogs,
applying the messages an agent sends, drawing a surface, and turning user
input into data model writes, actions and function calls. Each example
continues from the one before it.

## Catalogs and versions

Every A2UI message carries a protocol version, and every surface uses a
catalog of components and functions written for one version. The supported
versions are:

```elixir
A2UICore.supported_protocol_versions()
#=> ["v0.9", "v0.9.1", "v1.0"]
```

The basic catalog of each version ships with the package, with its functions
implemented:

```elixir
basic = A2UICore.Catalog.Basic.catalog("v1.0")
basic.catalog_id
#=> "https://a2ui.org/specification/v1_0/catalogs/basic/catalog.json"
```

`A2UICore.Catalog.Basic.declared/1` is the same catalog without
implementations, which is all an agent needs. The locale-sensitive functions
(`formatNumber`, `formatCurrency`, `formatDate`, `pluralize`) format as
`en-US`. For other locales, pass a module that implements `A2UICore.Formatter`
as the `:formatter` option of `A2UICore.Catalog.Basic.catalog/2`.

A catalog of your own is a catalog JSON document, loaded with
`A2UICore.Catalog.from_json/2`. Functions the renderer evaluates get their
implementations from `A2UICore.Catalog.put_implementations/2`:

```elixir
alias A2UICore.Catalog
alias A2UICore.Resolution.DataContext

shop =
  Catalog.from_json!(%{
    "catalogId" => "https://example.com/catalogs/shop.json",
    "protocolVersion" => "v1.0",
    "components" => %{},
    "functions" => %{
      "cartTotal" => %{
        "type" => "object",
        "returnType" => "number",
        "allowedCallers" => "rendererOrAgent",
        "properties" => %{
          "@call" => %{"const" => "cartTotal"},
          "args" => %{
            "type" => "object",
            "properties" => %{"taxRate" => %{"type" => "number"}},
            "required" => ["taxRate"]
          }
        },
        "required" => ["@call", "args"]
      }
    }
  })
  |> Catalog.put_implementations(%{
    "cartTotal" => fn %{"taxRate" => rate}, context ->
      {items, _effects} = DataContext.resolve_dynamic_value(context, %{"@path" => "/cart"})
      {:ok, Enum.sum(Enum.map(items, & &1["price"])) * (1 + rate)}
    end
  })
```

An implementation receives the validated arguments and the
`A2UICore.Resolution.DataContext` of the call, and returns `{:ok, value}` or
`{:error, %A2UICore.Error{}}`.

A message can only use a catalog whose version is compatible with its own. A
v0.9 message may create a surface on the v0.9.1 basic catalog, but not on the
v1.0 one; that fails with `VERSION_MISMATCH`.

## Applying messages

An `A2UICore.Processor` holds the catalogs and the surfaces. It is a plain
value: every call returns the next one, and nothing runs in the background.

```elixir
alias A2UICore.{Processor, Validation}

processor = Processor.new([basic, shop], validation: Validation.Config.strict())
```

A surface's default catalog is the one its `createSurface` names. A v1.0
surface may name none: it then has no default, and each component and
function call on it names its own `catalogId`. Before v1.0 the first
catalog is the default for a surface that names none.
`A2UICore.Processor.process/3` takes a payload as the transport delivers it
(one message, a list of messages, or a `%{"messages" => [...]}` wrapper) and
applies the messages in order:

```elixir
{:ok, processor, effects} =
  Processor.process(processor, [
    %{
      "version" => "v1.0",
      "createSurface" => %{"surfaceId" => "checkout", "catalogId" => basic.catalog_id}
    },
    %{
      "version" => "v1.0",
      "updateComponents" => %{
        "surfaceId" => "checkout",
        "components" => [
          %{"id" => "root", "component" => "Column", "children" => ["name", "greeting", "pay"]},
          %{
            "id" => "name",
            "component" => "TextField",
            "label" => "Name",
            "value" => %{"@path" => "/name"}
          },
          %{"id" => "greeting", "component" => "Text", "text" => %{"@path" => "/name"}},
          %{
            "id" => "pay",
            "component" => "Button",
            "child" => "payLabel",
            "action" => %{
              "event" => %{"name" => "pay", "context" => %{"name" => %{"@path" => "/name"}}}
            }
          },
          %{"id" => "payLabel", "component" => "Text", "text" => "Pay"}
        ]
      }
    },
    %{
      "version" => "v1.0",
      "updateDataModel" => %{
        "surfaceId" => "checkout",
        "path" => "/cart",
        "value" => [%{"price" => 10}, %{"price" => 30}]
      }
    }
  ])

effects
#=> [
#=>   {:surface_created, "checkout"},
#=>   {:components_updated, "checkout", ["root", "name", "greeting", "pay", "payLabel"]},
#=>   {:data_model_updated, "checkout", "/cart"}
#=> ]
```

The effects tell the host what changed:

| Effect | Meaning |
|---|---|
| `{:surface_created, id}` | a surface was created |
| `{:surface_deleted, id}` | a surface was deleted |
| `{:components_updated, id, component_ids}` | components were added or replaced |
| `{:data_model_updated, id, path}` | the data model changed at `path` |
| `{:rpc_response, message}` | the answer to the agent's function call, to send back |
| `{:rpc_settled, call_id, outcome}` | a function call to the agent was settled |

### Rejected messages

`process/3` stops at the first message that fails and returns
`{:error, error, processor}`. Messages before the failing one stay applied, so
the processor in the error tuple is the one to keep. A single
`updateComponents` is atomic: with a validation configuration, the batch is
checked as a whole and nothing in it is committed when it fails.

```elixir
{:error, error, processor} =
  Processor.process(processor, %{
    "version" => "v1.0",
    "updateComponents" => %{
      "surfaceId" => "checkout",
      "components" => [%{"id" => "root", "component" => "Column", "children" => ["missing"]}]
    }
  })

error.category
#=> :integrity
```

Errors are `A2UICore.Error` structs. The category says what went wrong:
`:validation` for a message that breaks the schema or the catalog,
`:integrity` for an unknown surface or a broken component graph, `:data` for
an invalid data path, and so on. The renderer reports an error to the agent
with `A2UICore.Message.RendererToAgent.error/3`.

### Validation

`A2UICore.Validation.Config.strict/0` requires a `root` component and rejects
dangling references, components unreachable from the root, and component types
the catalog does not define. `A2UICore.Validation.Config.relaxed/0` allows all
of these, for surfaces that arrive in pieces, and
`A2UICore.Validation.Config.new/1` sets each option on its own. Its
`:allowed_messages` option limits the messages a renderer accepts.

Without the `:validation` option, component batches are committed without
these checks. Every message is still checked against the protocol schema of
its version.

## Drawing a surface

A surface stores components as a flat list. `A2UICore.Resolution.NodeResolver`
turns them into the tree a renderer draws, with data bindings resolved:

```elixir
alias A2UICore.Resolution.NodeResolver

surface = Processor.surface(processor, "checkout")
{resolver, _notifications} = NodeResolver.new(surface)

positions = NodeResolver.positions(resolver)
positions |> Map.keys() |> Enum.sort()
#=> ["root", "root/children/0", "root/children/1", "root/children/2", "root/children/2/child"]
```

Each `A2UICore.Resolution.Node` has a `ref` that stays the same while its
position holds the same component, a `type`, a `state` (`:resolved`, or a
placeholder: `:pending`, `:unknown_type`, `:cyclic`), and `props`. A bound
property is an `A2UICore.Resolution.Binding` with the current value and the
path it reads, a child is `{:node, ref}`, and an action is an
`A2UICore.Resolution.Action`.

```elixir
greeting = positions["root/children/1"]
greeting.props["text"]
#=> %A2UICore.Resolution.Binding{value: nil, path: "/name"}
```

The resolver does not watch the surface. After the processor changes it,
pass the new surface to `A2UICore.Resolution.NodeResolver.update/2`. It
returns notifications naming the nodes to redraw (`{:node_created, ref}`,
`{:node_updated, ref}`, `{:node_destroyed, ref}`), plus warnings such as a
binding to a path that does not exist yet.

## User input

A two-way binding such as a text field's `value` becomes a write to the data
model. `A2UICore.Resolution.NodeResolver.write/4` returns the path a write
reaches, and `A2UICore.Processor.set_data/4` performs it:

```elixir
name_field = positions["root/children/0"]
{:ok, path, value} = NodeResolver.write(resolver, name_field.ref, "value", "Ada")
{:ok, processor, _effects} = Processor.set_data(processor, "checkout", path, value)

surface = Processor.surface(processor, "checkout")
{resolver, notifications} = NodeResolver.update(resolver, surface)

notifications
#=> [node_updated: name_field.ref, node_updated: greeting.ref]

NodeResolver.node(resolver, greeting.ref).props["text"].value
#=> "Ada"
```

Pressing the button invokes its action.
`A2UICore.Resolution.NodeResolver.invoke/5` resolves the action's context
against the current data and returns the event, which
`A2UICore.Message.RendererToAgent.action/2` wraps into the message for the
agent:

```elixir
pay = positions["root/children/2"]

{:ok, [{:action_event, event}]} =
  NodeResolver.invoke(resolver, surface, pay.ref, "action", ~U[2026-10-14 12:00:00Z])

A2UICore.Message.RendererToAgent.action(event)
#=> %{
#=>   "version" => "v1.0",
#=>   "action" => %{
#=>     "name" => "pay",
#=>     "surfaceId" => "checkout",
#=>     "sourceComponentId" => "pay",
#=>     "timestamp" => "2026-10-14T12:00:00Z",
#=>     "context" => %{"name" => "Ada"}
#=>   }
#=> }
```

An action that calls a catalog function instead (`openUrl`, for example) runs
the function and produces no event.

## MCP tools

The A2UI MCP catalog lets a surface call
[Model Context Protocol](https://modelcontextprotocol.io) tools.
`a2ui_core` makes no connections of its own: the host wraps its MCP client
in a module implementing `A2UICore.MCP.Client` and passes it to the
catalog:

```elixir
defmodule Weather do
  @behaviour A2UICore.MCP.Client

  @impl true
  def call_tool(_state, "get_weather", %{"city" => city}) do
    {:ok,
     %{
       "content" => [%{"type" => "text", "text" => "Sunny in #{city}"}],
       "structuredContent" => %{"city" => city, "sky" => "sunny"}
     }}
  end
end

mcp = A2UICore.Catalog.MCP.catalog("v1.0", client: {Weather, nil})
mcp.catalog_id
#=> "https://a2ui.org/specification/v1_0/catalogs/mcp/catalog.json"
```

`callMcpTool` returns the tool's result. The A2UI messages a result
carries come back as effects for the renderer to apply, and so do the
data model writes of `updateDataModel` and of `targetDataPath`:

```elixir
context =
  DataContext.new("/",
    catalog: mcp,
    protocol_version: "v1.0",
    data_model: A2UICore.State.DataModel.new(%{})
  )

call = %{
  "@call" => "callMcpTool",
  "args" => %{"name" => "get_weather", "arguments" => %{"city" => "Oslo"}}
}

{result, _effects} = DataContext.resolve_dynamic_value(context, call)
result["structuredContent"]
#=> %{"city" => "Oslo", "sky" => "sunny"}
```

The v0.9 catalog adds functions that shape a tool's output: `jmespath`,
`split`, `regexCapture`, `regexReplace` and `updateDataModel`. A typical
call reads a tool result with JMESPath and writes it to the data model:

```elixir
mcp09 = A2UICore.Catalog.MCP.catalog("v0.9", client: {Weather, nil})
context = DataContext.new("/", catalog: mcp09, protocol_version: "v0.9")

weather = %{
  "call" => "callMcpTool",
  "args" => %{"name" => "get_weather", "arguments" => %{"city" => "Oslo"}}
}

shape = %{
  "call" => "jmespath",
  "args" => %{"expression" => ~S|{"/sky": structuredContent.sky}|, "data" => weather}
}

{nil, effects} =
  DataContext.resolve_dynamic_value(context, %{
    "call" => "updateDataModel",
    "args" => %{"updates" => shape}
  })

effects
#=> [write: %{path: "/sky", value: "sunny"}]
```

`A2UICore.JMESPath` is the evaluator behind `jmespath`, usable on its own:

```elixir
forecast = %{"days" => [%{"name" => "Mon", "temp" => 18}, %{"name" => "Tue", "temp" => 23}]}
A2UICore.JMESPath.search("days[?temp > `20`].name", forecast)
#=> {:ok, ["Tue"]}
```

## Function calls

Protocol v1.0 lets the agent call functions in the renderer, and the
renderer call functions in the agent.

### The agent calls the renderer

A `callRendererFunction` message runs a function of the catalog it names
and produces an `{:rpc_response, message}` effect, the message to send back.
The function runs in the data context of the surface the message names in
`surfaceId`; arguments that are bindings or calls are resolved there first.
A message that names no surface runs in a context of its own, with an empty
data model:

```elixir
{:ok, processor, [rpc_response: response]} =
  Processor.process(processor, %{
    "version" => "v1.0",
    "callRendererFunction" => %{
      "functionCallId" => "fc-1",
      "surfaceId" => "checkout",
      "callFunction" => %{
        "@call" => "cartTotal",
        "catalogId" => shop.catalog_id,
        "args" => %{"taxRate" => 0.25}
      }
    }
  })

response
#=> %{
#=>   "version" => "v1.0",
#=>   "rendererFunctionResponse" => %{"functionCallId" => "fc-1", "value" => 50.0}
#=> }
```

The agent may only call functions whose `allowedCallers` is `agentOnly` or
`rendererOrAgent`. A function that does not say is renderer-only. A function
with `requiresUserActivation` runs only when the message is processed with
`user_activated: true`. Failures still produce a response: it carries an
`error` with a code such as `INVALID_FUNCTION_CALL` (also for a `surfaceId`
that names no surface) or `EXECUTION_ERROR`.

### The renderer calls the agent

`A2UICore.Processor.call_agent_function/4` registers a pending call and
returns the message to send:

```elixir
{:ok, processor, message} =
  Processor.call_agent_function(processor, "checkout", %{
    "@call" => "lookupAddress",
    "args" => %{"zip" => "10115"}
  })

message
#=> %{
#=>   "version" => "v1.0",
#=>   "callAgentFunction" => %{
#=>     "surfaceId" => "checkout",
#=>     "functionCallId" => "call-1",
#=>     "callFunction" => %{"@call" => "lookupAddress", "args" => %{"zip" => "10115"}}
#=>   }
#=> }

Processor.agent_call_timeout(processor, "call-1")
#=> 30000
```

The processor keeps no clock. The host starts a timer for the call, for
example with `Process.send_after/3`. The call is settled by the agent's
`agentFunctionResponse`:

```elixir
{:ok, processor, effects} =
  Processor.process(processor, %{
    "version" => "v1.0",
    "agentFunctionResponse" => %{"functionCallId" => "call-1", "value" => %{"city" => "Berlin"}}
  })

effects
#=> [{:rpc_settled, "call-1", {:ok, %{"city" => "Berlin"}}}]
```

If the timer fires first, `A2UICore.Processor.timeout_agent_call/2` settles
the call with a `TIMEOUT` error. `A2UICore.Processor.cancel_agent_call/3` and
`A2UICore.Processor.dispose/1` settle pending calls with `CANCELLED`.

## Capabilities

The renderer tells the agent which catalogs it supports:

```elixir
Processor.renderer_capabilities(processor, versions: ["v1.0"])
#=> {:ok,
#=>  %{
#=>    "v1.0" => %{
#=>      "supportedCatalogIds" => [
#=>        "https://a2ui.org/specification/v1_0/catalogs/basic/catalog.json",
#=>        "https://example.com/catalogs/shop.json"
#=>      ]
#=>    }
#=>  }}
```

With `include_inline_catalogs: true` the capabilities also carry each
catalog's schema, for agents that do not know the catalog. A surface created
with `"sendDataModel" => true` asks for its data model to travel with every
message to the agent. `A2UICore.Processor.renderer_data_model/2` collects the
data models of those surfaces. How either reaches the agent is up to the
transport. Over A2A both travel in message metadata.

## Lower-level modules

The processor is built from modules that can also be used on their own:

- `A2UICore.Message` decodes payloads into version-neutral operations and
  encodes operations back into messages.
  `A2UICore.Processor.apply_operations/3` applies decoded operations.
- `A2UICore.State.Surface` and `A2UICore.State.DataModel` hold a surface and
  its data.
- `A2UICore.Expression` parses `${...}` templates, and
  `A2UICore.Resolution.DataContext` evaluates bindings and function calls.
- `A2UICore.Schema` is the JSON Schema validator the message and catalog
  checks use; `A2UICore.Schema.ECMA262` runs its regular expressions.
- `A2UICore.MCP` reads A2UI out of MCP tool results and resources.
- `A2UICore.RPC` is the function-call state machine behind the processor.

# A2UICore

The protocol engine of [A2UI](https://a2ui.org) for Elixir: versioned message
envelopes, JSON Schema validation of messages and catalogs, surface state and
data models, catalog functions and expressions, node resolution for renderers,
and function calls between renderer and agent. It supports protocol versions
v0.9, v0.9.1 and v1.0 and is checked against the upstream conformance suites.

Everything is plain data. A processor is a value that each message updates,
and what happened comes back as effects for the host to act on. There are no
processes, and the only dependency is Jason.

## Installation

```elixir
def deps do
  [
    {:a2ui_core, "~> 0.1.0"}
  ]
end
```

## Usage

```elixir
alias A2UICore.{Processor, Validation}
alias A2UICore.Resolution.NodeResolver

catalog = A2UICore.Catalog.Basic.catalog("v1.0")
processor = Processor.new([catalog], validation: Validation.Config.strict())

{:ok, processor, effects} =
  Processor.process(processor, [
    %{
      "version" => "v1.0",
      "createSurface" => %{"surfaceId" => "main", "catalogId" => catalog.catalog_id}
    },
    %{
      "version" => "v1.0",
      "updateComponents" => %{
        "surfaceId" => "main",
        "components" => [
          %{"id" => "root", "component" => "Column", "children" => ["greeting"]},
          %{"id" => "greeting", "component" => "Text", "text" => %{"@path" => "/name"}}
        ]
      }
    },
    %{
      "version" => "v1.0",
      "updateDataModel" => %{"surfaceId" => "main", "path" => "/name", "value" => "Ada"}
    }
  ])

effects
#=> [{:surface_created, "main"}, {:components_updated, "main", ["root", "greeting"]},
#    {:data_model_updated, "main", "/name"}]

# The tree a renderer draws, with bindings resolved.
{resolver, _notifications} = NodeResolver.new(Processor.surface(processor, "main"))
root = NodeResolver.root(resolver)
[greeting] = Enum.map(root.children, &NodeResolver.node(resolver, &1))
greeting.props["text"].value
#=> "Ada"
```

A message the renderer must reject is an error, and the processor it returns
is the one to keep:

```elixir
{:error, %A2UICore.Error{category: :integrity}, processor} =
  Processor.process(processor, %{
    "version" => "v1.0",
    "updateComponents" => %{
      "surfaceId" => "main",
      "components" => [%{"id" => "root", "component" => "Column", "children" => ["missing"]}]
    }
  })
```

See the [processing guide](guides/processing_messages.md) for the rest: versions
and catalogs, validation, the data model, actions and function calls.

## License

Apache-2.0. The JSON schemas and catalogs under `priv/schemas` and
`priv/catalogs` are copies of the A2UI specification's files, with its
license file (`priv/LICENSE-APACHE`).

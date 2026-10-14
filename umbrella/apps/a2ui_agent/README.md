# A2UIAgent

The agent side of [A2UI](https://a2ui.org) for Elixir, built on `a2ui_core`.
An agent registers the catalogs it can write for, negotiates them with each
renderer, puts the matching schemas in the model's prompt and reads the
model's output back as validated A2UI messages, from a complete response or
chunk by chunk while it streams.

It supports protocol versions v0.9, v0.9.1 and v1.0. The inference format is
direct JSON: the model writes message lists between `<a2ui-json>` and
`</a2ui-json>` tags.

## Usage

```elixir
alias A2UIAgent.{CatalogConfig, CatalogTransformer, Generator, RequestProcessor}
alias A2UIAgent.DirectJson.Parser

# Once, when the agent starts.
basic =
  CatalogConfig.new(A2UICore.Catalog.Basic.catalog("v1.0"),
    transformers: [CatalogTransformer.component_pruning(["Column", "Text", "Button"])]
  )

generator = Generator.new([basic], examples: [example_turn])

# Per request, with the capabilities the renderer sent.
{:ok, processor} = Generator.create_processor(generator, capabilities)
{:ok, snippet} = RequestProcessor.prompt(processor)

# A complete response...
{:ok, parts} = RequestProcessor.parse_response(processor, model_output)
#=> [{:text, "Here is your form."}, {:a2ui, [%{"version" => "v1.0", ...}, ...]}]

# ...or a streamed one, chunk by chunk.
parser = RequestProcessor.parser(processor)
{:ok, parser, parts} = Parser.parse_chunk(parser, chunk)
```

`snippet` goes into the model's system prompt. Each `{:a2ui, messages}` part
holds messages that a renderer holding the negotiated catalogs accepts
(`A2UIAgent.PayloadValidator`). Send them to the renderer over whatever
transport connects the two.

Catalogs can also be loaded from files (`A2UIAgent.CatalogConfig.from_path/2`)
or sent by the renderer itself (`inlineCatalogs`, with
`accepts_inline_catalogs: true`).

## License

Apache-2.0

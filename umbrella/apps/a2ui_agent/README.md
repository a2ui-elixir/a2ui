# A2UIAgent

The agent side of [A2UI](https://a2ui.org) for Elixir, built on `a2ui_core`.
An agent registers the catalogs it can write for, negotiates them with each
renderer, puts the matching schemas in the model's prompt and reads the
model's output back as validated A2UI messages, from a complete response or
chunk by chunk while it streams.

It supports protocol versions v0.9, v0.9.1 and v1.0, and two inference
formats. In direct JSON, the default, the model writes message lists between
`<a2ui-json>` and `</a2ui-json>` tags. In Express (`A2UIAgent.Express`) it
writes a compact notation between `<a2ui>` and `</a2ui>` tags, which the agent
compiles into messages. An Express prompt can also be packaged as skills
(`A2UIAgent.SkillGenerator`).

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

For Express, pass `format: A2UIAgent.Express` to `Generator.new/2` (every
request) or `Generator.create_processor/3` (one request). Express responses
are parsed once they are complete.

## Serving over A2A

`A2UIAgent.A2A.Plug` serves an agent over the JSON-RPC binding of
[A2A](https://a2a-protocol.org): `message/send` answers with the finished task,
`message/stream` with server-sent events.

```elixir
defmodule MyAgent do
  @behaviour A2UIAgent.A2A.Agent

  alias A2UIAgent.A2A.Request

  # No catalog negotiated: answer in text.
  @impl true
  def run(%Request{processor: nil, text: text}), do: {:ok, MyModel.reply(text)}

  # `events` holds the renderer's A2UI messages, such as actions.
  def run(%Request{processor: processor, text: text, events: events}) do
    {:ok, prompt} = A2UIAgent.RequestProcessor.prompt(processor)
    # A string, or an enumerable of chunks as the model streams them.
    {:ok, MyModel.stream(prompt, text, events)}
  end

  @impl true
  def options do
    basic = A2UIAgent.CatalogConfig.new(A2UICore.Catalog.Basic.catalog("v1.0"))
    [generator: A2UIAgent.Generator.new([basic])]
  end

  @impl true
  def card do
    %{
      "name" => "My agent",
      "capabilities" => %{"extensions" => [A2UIAgent.A2A.agent_extension("1.0")]}
    }
  end
end

# In a Phoenix router or a Plug.Router:
forward "/a2a", A2UIAgent.A2A.Plug, agent: MyAgent
```

The renderer's capabilities, which it sends in the message metadata, select the
catalogs. The model's output goes back as a text part for each run of text and
an A2UI data part for each message. `A2UIAgent.A2A.Server` does the same
without Plug, and `A2UIAgent.A2A` holds the part and extension helpers. The
plug needs the optional `plug` dependency.

## License

Apache-2.0

# Serving an agent

`a2ui_agent` is the agent's side of A2UI. The agent declares the catalogs it
can write for and agrees with each renderer on the ones they share. It puts
those catalogs' schemas in the model's prompt and reads the model's output
back as messages a renderer will accept. `A2UIAgent.A2A` serves the result
over A2A. Each example continues from the one before it.

## Catalogs

An agent registers each catalog it can write for as an
`A2UIAgent.CatalogConfig`. Transformers narrow a catalog to what the agent
needs. A smaller catalog makes a shorter prompt and gives the model fewer
ways to go wrong:

```elixir
alias A2UIAgent.{CatalogConfig, CatalogTransformer, Generator, RequestProcessor}

basic = A2UICore.Catalog.Basic.catalog("v1.0")

config =
  CatalogConfig.new(basic,
    transformers: [
      CatalogTransformer.component_pruning(["Column", "Text", "TextField", "Button"])
    ]
  )

config.transformed.components |> Map.keys() |> Enum.sort()
#=> ["Button", "Column", "Text", "TextField"]
```

`A2UIAgent.CatalogConfig.from_path/2` loads a catalog from a JSON file
instead.

A `A2UIAgent.Generator` holds the registered catalogs and the few-shot
examples for the prompt. An example is a list of messages, and it must be
valid in the agent's catalogs:

```elixir
example = [
  %{
    "version" => "v1.0",
    "createSurface" => %{"surfaceId" => "hello", "catalogId" => basic.catalog_id}
  },
  %{
    "version" => "v1.0",
    "updateComponents" => %{
      "surfaceId" => "hello",
      "components" => [%{"id" => "root", "component" => "Text", "text" => "Hello!"}]
    }
  }
]

generator = Generator.new([config], examples: [example])
```

Build the generator once, when the agent starts.

## Each request

A renderer says which catalogs it supports, keyed by protocol version.
`A2UIAgent.Generator.create_processor/3` keeps the agent's catalogs that the
renderer names and returns an `A2UIAgent.RequestProcessor` for them:

```elixir
capabilities = %{"v1.0" => %{"supportedCatalogIds" => [basic.catalog_id]}}
{:ok, processor} = Generator.create_processor(generator, capabilities)
```

When the renderer names none of the agent's catalogs, there is nothing to
write for. The agent should answer in text:

```elixir
{:error, error} =
  Generator.create_processor(generator, %{
    "v1.0" => %{"supportedCatalogIds" => ["https://example.com/catalogs/other.json"]}
  })

error.category
#=> :catalog
```

A renderer can also send catalogs inline, under `"inlineCatalogs"`. The
generator uses them only when it was built with
`accepts_inline_catalogs: true`.

## The prompt

`A2UIAgent.RequestProcessor.prompt/1` returns the part of the system prompt
that teaches the model A2UI. It has the rules of the output format, the JSON
schemas of the negotiated catalogs, and the examples:

```elixir
{:ok, snippet} = RequestProcessor.prompt(processor)

snippet |> String.split("\n") |> hd()
#=> "## Workflow Description:"
```

Add the rest of the system prompt yourself: who the agent is and what it does.

## Reading the model's output

The model writes direct JSON: ordinary text, with lists of A2UI messages
between `<a2ui-json>` and `</a2ui-json>` tags.
`A2UIAgent.RequestProcessor.parse_response/3` splits a complete response into
text and messages, and checks the messages the way a renderer holding the
negotiated catalogs would:

```elixir
model_output = """
Here is a form.
<a2ui-json>
[
  {"version": "v1.0",
   "createSurface": {"surfaceId": "form",
                     "catalogId": "https://a2ui.org/specification/v1_0/catalogs/basic/catalog.json"}},
  {"version": "v1.0",
   "updateComponents": {"surfaceId": "form", "components": [
     {"id": "root", "component": "Column", "children": ["name"]},
     {"id": "name", "component": "TextField", "label": "Name", "value": {"@path": "/name"}}
   ]}}
]
</a2ui-json>
"""

{:ok, [{:text, text}, {:a2ui, messages}]} = RequestProcessor.parse_response(processor, model_output)

text
#=> "Here is a form."

Enum.map(messages, &(&1 |> Map.delete("version") |> Map.keys()))
#=> [["createSurface"], ["updateComponents"]]
```

The reader forgives small JSON mistakes models make, such as trailing commas,
raw line breaks in strings, curly quotes and a Markdown code fence around a
block. It does not accept messages a renderer would reject. A component the
transformers pruned away, for example, is an error:

```elixir
{:error, error} =
  RequestProcessor.parse_response(processor, """
  <a2ui-json>
  [{"version": "v1.0",
    "createSurface": {"surfaceId": "pic",
                      "catalogId": "https://a2ui.org/specification/v1_0/catalogs/basic/catalog.json"}},
   {"version": "v1.0",
    "updateComponents": {"surfaceId": "pic", "components": [
      {"id": "root", "component": "Image", "url": "https://example.com/cat.png"}]}}]
  </a2ui-json>
  """)

error.category
#=> :validation
```

The error message says what is wrong. Giving it back to the model is a good
way to get a corrected response.

### Streaming

A model's response usually arrives in chunks. The parser that
`A2UIAgent.RequestProcessor.parser/1` returns reads one chunk at a time with
`A2UIAgent.DirectJson.Parser.parse_chunk/3`. It emits text as it arrives, and
each message as soon as it is valid:

```elixir
alias A2UIAgent.DirectJson.Parser

chunks = Regex.split(~r/(?<=\n)/, model_output)

{_parser, parts} =
  Enum.reduce(chunks, {RequestProcessor.parser(processor), []}, fn chunk, {parser, parts} ->
    {:ok, parser, new_parts} = Parser.parse_chunk(parser, chunk)
    {parser, parts ++ new_parts}
  end)

summary =
  Enum.map(parts, fn
    {:text, text} ->
      text

    {:a2ui, [%{"createSurface" => %{"surfaceId" => id}}]} ->
      {:create, id}

    {:a2ui, [%{"updateComponents" => %{"components" => components}}]} ->
      {:components, Enum.map(components, & &1["id"])}
  end)

summary
#=> ["Here is a form.", {:create, "form"}, {:components, ["root"]}, {:components, ["root", "name"]}]
```

A message can be emitted again as it grows. Here the `updateComponents`
message comes out first with the components read so far, then again when the
next one arrives, so the renderer can draw the surface while the model is
still writing it. A `createSurface` is held back until it is complete, and so
is every message after it. When a block closes, it is checked as a whole, so
a block that turns out to be invalid fails at that point.

## Serving over A2A

`A2UIAgent.A2A.Plug` serves an agent over the JSON-RPC binding of
[A2A](https://a2a-protocol.org). The agent is a module implementing
`A2UIAgent.A2A.Agent`:

```elixir
defmodule GreetingAgent do
  @behaviour A2UIAgent.A2A.Agent

  alias A2UIAgent.A2A.Request

  # No catalog negotiated: answer in text.
  @impl true
  def run(%Request{processor: nil, text: text}), do: {:ok, "Hello, #{text}!"}

  # `events` holds the renderer's messages, such as the actions of its users.
  def run(%Request{processor: processor, text: text, events: _events}) do
    {:ok, prompt} = A2UIAgent.RequestProcessor.prompt(processor)
    {:ok, call_model(prompt, text)}
  end

  @impl true
  def options do
    basic = A2UIAgent.CatalogConfig.new(A2UICore.Catalog.Basic.catalog("v1.0"))
    [generator: A2UIAgent.Generator.new([basic])]
  end

  @impl true
  def card do
    %{
      "name" => "Greeting agent",
      "capabilities" => %{"extensions" => [A2UIAgent.A2A.agent_extension("1.0")]}
    }
  end

  # Stands in for the model, which gets the prompt and the user's text.
  defp call_model(_prompt, text) do
    """
    Hello!
    <a2ui-json>
    [{"version": "v1.0",
      "createSurface": {"surfaceId": "hello",
                        "catalogId": "https://a2ui.org/specification/v1_0/catalogs/basic/catalog.json"}},
     {"version": "v1.0",
      "updateComponents": {"surfaceId": "hello", "components": [
        {"id": "root", "component": "Text", "text": "Hello, #{text}!"}]}}]
    </a2ui-json>
    """
  end
end
```

`run/1` gets an `A2UIAgent.A2A.Request`. When the renderer's capabilities
match a catalog of the generator, `processor` is the request processor for
them. Otherwise it is `nil`, and the answer is text. The model's output can
be a string, or an enumerable of chunks as the model streams them.

Mount the plug in a Phoenix router or a `Plug.Router`. It needs the optional
`plug` dependency, which Phoenix applications already have:

```elixir
forward "/a2a", A2UIAgent.A2A.Plug, agent: GreetingAgent
```

`POST` answers JSON-RPC: `message/send` with the finished task, and
`message/stream` with server-sent events as the output arrives. `GET` serves
the agent card. The renderer sends its capabilities in the message metadata,
as `a2uiRendererCapabilities` (`a2uiClientCapabilities` in protocol v0.9).
The answer has a text part for each run of text and a data part for each
A2UI message.

`A2UIAgent.A2A.Server.handle/3` does the same work without HTTP. It is
convenient in tests:

```elixir
body = %{
  "jsonrpc" => "2.0",
  "id" => 1,
  "method" => "message/send",
  "params" => %{
    "message" => %{
      "kind" => "message",
      "messageId" => "m1",
      "role" => "user",
      "parts" => [%{"kind" => "text", "text" => "Ada"}],
      "metadata" => %{
        "a2uiRendererCapabilities" => %{
          "v1.0" => %{"supportedCatalogIds" => [basic.catalog_id]}
        }
      }
    }
  }
}

{:reply, response, _extensions} =
  A2UIAgent.A2A.Server.handle(body, GreetingAgent, GreetingAgent.options())

parts = response["result"]["status"]["message"]["parts"]
Enum.map(parts, & &1["kind"])
#=> ["text", "data", "data"]

A2UIAgent.A2A.a2ui_messages(parts) |> List.last() |> get_in(["updateComponents", "components"])
#=> [%{"id" => "root", "component" => "Text", "text" => "Hello, Ada!"}]
```

`A2UIAgent.A2A` also has the helpers for building and reading A2UI parts and
for negotiating the A2UI extension.

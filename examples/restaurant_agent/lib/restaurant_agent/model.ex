defmodule RestaurantAgent.Model do
  @moduledoc """
  A scripted stand-in for the language model.

  A real agent gives the prompt (`A2UIAgent.RequestProcessor.prompt/1`)
  and the conversation to a model, which answers with text and A2UI
  messages in the format the prompt teaches. This module writes the same
  kind of answer without a model, so the examples run offline and their
  tests are deterministic:

    * in direct JSON, the restaurant list uses the `RestaurantCard`
      macro, as a model would after reading the prompt; the agent expands
      the macro before the answer reaches the renderer;
    * in Express, the messages are written back with
      `A2UIAgent.Express.Parser.decompile/2`.

  `stream/2` splits an answer into chunks and paces them, the way a
  model's answer arrives.
  """

  alias A2UIAgent.Express
  alias RestaurantAgent.{Catalogs, UI}

  @doc """
  The restaurant list as the model writes it in v1.0: a template of
  `RestaurantCard` macros, each with a `Rating` from the restaurant
  catalog.
  """
  @spec list(String.t(), String.t(), [map()], String.t()) :: [map()]
  def list(surface_id, heading, restaurants, base_url) do
    [
      %{
        "version" => "v1.0",
        "createSurface" => %{
          "surfaceId" => surface_id,
          "catalogId" => Catalogs.basic("v1.0").catalog_id,
          "components" => [
            %{
              "id" => "root",
              "component" => "Column",
              "children" => ["title", "summary", "list"]
            },
            %{"id" => "title", "component" => "Text", "text" => "## " <> heading},
            %{
              "id" => "summary",
              "component" => "Text",
              "variant" => "caption",
              "text" => %{
                "@call" => "pluralize",
                "args" => %{
                  "value" => %{"@path" => "/count"},
                  "one" => "One place nearby.",
                  "other" => %{
                    "@call" => "formatString",
                    "args" => %{"value" => "${/count} places nearby, nearest first."}
                  }
                }
              }
            },
            %{
              "id" => "list",
              "component" => "List",
              "direction" => "vertical",
              "children" => %{"componentId" => "card", "path" => "/restaurants"}
            },
            %{
              "id" => "card",
              "component" => "RestaurantCard",
              "name" => %{"@path" => "name"},
              "image" => %{"@path" => "image"},
              "details" => %{
                "@call" => "formatString",
                "args" => %{
                  "value" =>
                    "${cuisine} · ${price} · ${formatNumber(value: ${distance}, decimals: 1)} km"
                }
              },
              "rating" => "stars",
              "action" => %{
                "event" => %{
                  "name" => "book",
                  "context" => %{
                    "restaurantId" => %{"@path" => "id"},
                    "name" => %{"@path" => "name"}
                  }
                }
              }
            },
            %{
              "id" => "stars",
              "component" => "Rating",
              "catalogId" => Catalogs.restaurant_id(),
              "value" => %{"@path" => "rating"},
              "label" => %{
                "@call" => "formatString",
                "args" => %{"value" => "${rating} · ${reviews} reviews"}
              }
            }
          ],
          "dataModel" => %{
            "count" => length(restaurants),
            "restaurants" => Enum.map(restaurants, &UI.item(&1, base_url))
          }
        }
      }
    ]
  end

  @doc "The few-shot example of the prompt: a list of one restaurant."
  @spec example() :: [map()]
  def example do
    restaurant = RestaurantAgent.Restaurants.get("trattoria-roma")
    list("example", "Italian restaurants near you", [restaurant], "https://example.com")
  end

  @doc """
  The answer to give: `text`, then the messages in the format of
  `parser` (an `A2UIAgent.DirectJson` or `A2UIAgent.Express` parser).
  """
  @spec write(String.t(), [map()], struct()) :: String.t()
  def write(text, [], _parser), do: text

  def write(text, messages, %Express.Parser{} = parser) do
    {:ok, express} =
      Express.Parser.decompile(parser, messages, surface_catalogs: surface_catalogs(messages))

    "#{text}\n<a2ui>\n#{express}\n</a2ui>\n"
  end

  def write(text, messages, _direct_json) do
    "#{text}\n<a2ui-json>\n#{Jason.encode!(messages, pretty: true)}\n</a2ui-json>\n"
  end

  # With several catalogs, Express reads a component's catalog from its
  # surface's createSurface. Every surface of this agent defaults to the
  # basic catalog, which tells the decompiler the catalog of surfaces
  # created in earlier turns.
  defp surface_catalogs(messages) do
    basic = Catalogs.basic("v1.0").catalog_id

    for message <- messages,
        {_operation, %{"surfaceId" => id}} <- Map.delete(message, "version"),
        into: %{},
        do: {id, basic}
  end

  @doc """
  `answer` in chunks of about `size` characters (split at whitespace
  where it can), each after `delay_ms`.
  """
  @spec stream(String.t(), keyword()) :: Enumerable.t()
  def stream(answer, options \\ []) do
    size = Keyword.get(options, :size, 48)

    delay =
      Keyword.get(options, :delay_ms, Application.get_env(:restaurant_agent, :chunk_delay_ms, 0))

    answer
    |> chunks(size)
    |> Stream.map(fn chunk ->
      if delay > 0, do: Process.sleep(delay)
      chunk
    end)
  end

  defp chunks(answer, size) do
    ~r/\S+\s*|\s+/u
    |> Regex.scan(answer)
    |> List.flatten()
    |> Enum.chunk_while(
      "",
      fn word, acc ->
        if String.length(acc) + String.length(word) > size and acc != "",
          do: {:cont, acc, word},
          else: {:cont, acc <> word}
      end,
      fn
        "" -> {:cont, ""}
        acc -> {:cont, acc, ""}
      end
    )
  end
end

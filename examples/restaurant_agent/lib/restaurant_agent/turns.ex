defmodule RestaurantAgent.Turns do
  @moduledoc """
  The answer to one message for the transports that carry finished
  messages (MCP, AG-UI, server-sent events, WebSocket): negotiate the
  catalogs with the renderer's capabilities, run the turn, and check and
  expand what the model wrote exactly as the A2A endpoint does.
  """

  alias A2UIAgent.Generator
  alias RestaurantAgent.{Agent, Catalogs, Turn}

  @default_capabilities %{
    "v1.0" => %{
      "supportedCatalogIds" => [
        "https://a2ui.org/specification/v1_0/catalogs/basic/catalog.json",
        "https://example.com/a2ui/catalogs/restaurant/v1/catalog.json"
      ]
    }
  }

  @doc "The capabilities assumed for a renderer that states none: v1.0, both catalogs."
  @spec default_capabilities() :: map()
  def default_capabilities, do: @default_capabilities

  @doc """
  Answers `text` and `events` for a renderer with `capabilities`.
  Returns the text and the messages to send, in the negotiated version.
  Options: `:turn_id`, and `:function_calls` (default `true`): whether
  the transport carries the renderer's answers to function calls back.
  """
  @spec answer(String.t(), [map()], map() | nil, keyword()) ::
          {:ok, %{text: String.t(), messages: [map()], version: String.t()}}
          | {:error, String.t()}
  def answer(text, events, capabilities, options \\ []) do
    with {:ok, processor} <- negotiate(capabilities || @default_capabilities) do
      [catalog | _] = A2UIAgent.RequestProcessor.active_catalogs(processor)
      version = Agent.wire_version(A2UIAgent.Catalogs.protocol_version(catalog))

      turn = %Turn{
        text: text,
        events: events,
        version: version,
        turn_id: Keyword.get_lazy(options, :turn_id, &new_id/0),
        base_url: RestaurantAgent.base_url(),
        function_calls: Keyword.get(options, :function_calls, true),
        catalogs: Enum.map(A2UIAgent.RequestProcessor.active_catalogs(processor), & &1.catalog_id)
      }

      %{text: said, messages: messages} = Turn.respond(turn)
      written = Agent.answer(processor, said, messages)

      case A2UIAgent.RequestProcessor.parse_response(processor, written) do
        {:ok, parts} ->
          {:ok,
           %{
             text: parts |> Enum.flat_map(&text_of/1) |> Enum.join("\n"),
             messages: Enum.flat_map(parts, &messages_of/1),
             version: version
           }}

        {:error, error} ->
          {:error, Exception.message(error)}
      end
    end
  end

  defp negotiate(capabilities) do
    Enum.reduce_while(Catalogs.generators(), {:error, "No catalog in common."}, fn generator,
                                                                                   error ->
      case Generator.create_processor(generator, capabilities) do
        {:ok, processor} -> {:halt, {:ok, processor}}
        {:error, _error} -> {:cont, error}
      end
    end)
  end

  defp text_of({:text, text}), do: [text]
  defp text_of(_part), do: []

  defp messages_of({:a2ui, messages}), do: messages
  defp messages_of(_part), do: []

  defp new_id, do: Integer.to_string(System.unique_integer([:positive]))
end

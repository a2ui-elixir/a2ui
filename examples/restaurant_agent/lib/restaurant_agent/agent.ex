defmodule RestaurantAgent.Agent do
  @moduledoc """
  The agent served over A2A (`A2UIAgent.A2A.Plug`), writing direct JSON.

  For each request the A2A server negotiates the catalogs with the
  renderer and hands over a request processor. The agent asks its model
  for an answer (`RestaurantAgent.Model`), checks it against the
  catalogs the prompt described, expands the `RestaurantCard` macro, and
  returns the answer as a stream of chunks, which the server parses into
  A2A parts as they arrive.
  """

  @behaviour A2UIAgent.A2A.Agent

  require Logger

  alias A2UIAgent.{A2A, MacroExpander, RequestProcessor}
  alias A2UIAgent.A2A.Request
  alias RestaurantAgent.{Catalogs, Model, Turn}

  @impl true
  def run(request), do: run(request, :direct_json)

  @doc "Answers `request`, with the model writing `format`."
  @spec run(Request.t(), :direct_json | :express) :: {:ok, Enumerable.t()}
  def run(%Request{processor: nil} = request, _format) do
    log(request, "text only")
    {:ok, Model.stream(Turn.text_only())}
  end

  def run(%Request{processor: processor} = request, format) do
    turn = %Turn{
      text: request.text,
      events: request.events,
      version: wire_version(request.version),
      format: format,
      turn_id: turn_id(request),
      base_url: RestaurantAgent.base_url(),
      catalogs: Enum.map(RequestProcessor.active_catalogs(processor), & &1.catalog_id)
    }

    log(request, describe(turn))
    %{text: text, messages: messages} = Turn.respond(turn)
    {:ok, Model.stream(answer(processor, text, messages))}
  end

  @doc """
  The answer to give for `text` and `messages`: what the model writes,
  read back as the renderer will read it, with the macros expanded.
  """
  @spec answer(RequestProcessor.t(), String.t(), [map()]) :: String.t()
  def answer(processor, text, messages) do
    parser = RequestProcessor.parser(processor)
    written = Model.write(text, messages, parser)

    case parser do
      %A2UIAgent.Express.Parser{} -> written
      _direct_json -> expand(processor, written)
    end
  end

  defp expand(processor, written) do
    with {:ok, parts} <- RequestProcessor.parse_response(processor, written),
         {:ok, parts} <- expand_parts(parts) do
      Enum.map_join(parts, "\n", fn
        {:text, text} -> text
        {:a2ui, messages} -> "<a2ui-json>\n#{Jason.encode!(messages)}\n</a2ui-json>"
      end)
    else
      {:error, error} ->
        Logger.error("the model's answer does not check: #{Exception.message(error)}")
        "Sorry, I wrote something I can't show. Please ask again."
    end
  end

  defp expand_parts(parts) do
    Enum.reduce_while(parts, {:ok, []}, fn
      {:a2ui, messages}, {:ok, acc} ->
        case MacroExpander.to_transport(Catalogs.expander(), messages) do
          {:ok, expanded} -> {:cont, {:ok, acc ++ [{:a2ui, expanded}]}}
          {:error, error} -> {:halt, {:error, error}}
        end

      part, {:ok, acc} ->
        {:cont, {:ok, acc ++ [part]}}
    end)
  end

  @impl true
  def options, do: [generator: Catalogs.generators()]

  @impl true
  def card, do: card("/a2a", "Finds restaurants and books tables, with A2UI surfaces.")

  @doc """
  The agent card of the endpoint at `path`. Option: `:catalogs`, the
  v1.0 catalogs it writes for (default: the basic and restaurant ones).
  """
  @spec card(String.t(), String.t(), keyword()) :: map()
  def card(path, description, options \\ []) do
    catalogs =
      Keyword.get_lazy(options, :catalogs, fn ->
        [Catalogs.basic("v1.0").catalog_id, Catalogs.restaurant_id()]
      end)

    %{
      "name" => "Restaurant finder",
      "description" => description,
      "url" => RestaurantAgent.base_url() <> path,
      "version" => "0.1.0",
      "protocolVersion" => "0.3.0",
      "preferredTransport" => "JSONRPC",
      "capabilities" => %{
        "streaming" => true,
        "extensions" => [
          A2A.agent_extension("1.0", supported_catalog_ids: catalogs),
          A2A.agent_extension("0.9", supported_catalog_ids: [Catalogs.basic("v0.9.1").catalog_id])
        ]
      },
      "defaultInputModes" => ["text/plain"],
      "defaultOutputModes" => ["text/plain", A2A.mime_type()],
      "skills" => [
        %{
          "id" => "find_restaurants",
          "name" => "Find restaurants",
          "description" => "Lists restaurants by cuisine and books a table at one of them.",
          "tags" => ["restaurants", "booking"],
          "examples" => ["Find Italian restaurants", "Show me Japanese places"]
        }
      ]
    }
  end

  @doc "The protocol version messages state for a catalog version."
  @spec wire_version(String.t() | nil) :: String.t()
  def wire_version("v1.0"), do: "v1.0"
  def wire_version(_v09), do: "v0.9"

  # Surfaces are named after the message that created them.
  defp turn_id(%Request{message: message}) do
    case message["messageId"] do
      id when is_binary(id) and id != "" ->
        id |> String.replace(~r/[^A-Za-z0-9_-]/, "") |> String.slice(0, 24)

      _none ->
        Integer.to_string(System.unique_integer([:positive]))
    end
  end

  defp describe(%Turn{events: [], text: text}), do: "text #{inspect(text)}"

  defp describe(%Turn{events: events}),
    do:
      "events " <>
        Enum.map_join(events, ", ", &(&1 |> Map.delete("version") |> Map.keys() |> hd()))

  defp log(request, what),
    do:
      Logger.info(
        "a2a #{request.method} #{request.version || "-"} context=#{request.context_id} #{what}"
      )
end

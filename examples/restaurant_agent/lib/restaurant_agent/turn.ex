defmodule RestaurantAgent.Turn do
  @moduledoc """
  What the agent does with one message: the conversation logic every
  transport shares.

  A message carries the user's text, or events from the renderer: the
  actions its users trigger, the agent functions it calls
  (`callAgentFunction`), its answers to the agent's function calls
  (`rendererFunctionResponse`) and the errors it reports. `respond/1`
  returns the text to say and the A2UI messages to send.

  The agent keeps no state between messages. What it needs travels with
  the messages: the action names the surface it came from, and the call
  id of `clientInfo` names the surface its answer is for.
  """

  require Logger

  alias RestaurantAgent.{Model, Restaurants, UI}

  defstruct text: "",
            events: [],
            version: "v1.0",
            format: :direct_json,
            turn_id: "1",
            base_url: "http://127.0.0.1:4001",
            today: nil,
            function_calls: true,
            catalogs: :all

  @typedoc """
  A message to answer: `version` is the protocol version of the messages
  to write (`"v1.0"` or `"v0.9"`), `format` the format the model writes
  (`:direct_json` or `:express`), `turn_id` names the surfaces the turn
  creates. `function_calls` is false on transports that cannot carry
  the renderer's answers to function calls back to the agent.
  `catalogs` lists the ids of the catalogs negotiated with the renderer
  (`:all` for every catalog of the agent): without the restaurant
  catalog there is no `Rating` and no function call.
  """
  @type t :: %__MODULE__{
          text: String.t(),
          events: [map()],
          version: String.t(),
          format: :direct_json | :express,
          turn_id: String.t(),
          base_url: String.t(),
          today: Date.t() | nil,
          function_calls: boolean(),
          catalogs: :all | [String.t()]
        }

  @type reply :: %{text: String.t(), messages: [map()]}

  @help "Ask me for restaurants, for example \"Find Italian restaurants\" " <>
          "(I know #{Enum.join(Restaurants.cuisines(), ", ")} places)."

  @doc "The answer for a renderer that cannot show A2UI."
  @spec text_only() :: String.t()
  def text_only,
    do:
      "I can find restaurants and book tables, but I need an A2UI renderer to show them. " <>
        @help

  @doc "Answers one message."
  @spec respond(t()) :: reply()
  def respond(%__MODULE__{events: [_ | _] = events} = turn) do
    Enum.reduce(events, %{text: "", messages: []}, fn event, reply ->
      %{text: text, messages: messages} = event(event, turn)
      %{text: join(reply.text, text), messages: reply.messages ++ messages}
    end)
  end

  def respond(%__MODULE__{text: text} = turn) do
    cond do
      String.trim(text) == "" or Regex.match?(~r/\b(help|hello|hi|hey)\b/i, text) ->
        say("Hello! " <> @help)

      true ->
        search(turn, text)
    end
  end

  defp search(turn, text) do
    case Restaurants.search(text) do
      {_cuisine, []} ->
        say("I don't know restaurants like that. " <> @help)

      {cuisine, found} ->
        heading = if cuisine, do: "#{cuisine} restaurants near you", else: "Restaurants near you"
        surface_id = "restaurants-" <> turn.turn_id

        messages =
          if turn.version == "v1.0" and turn.format == :direct_json and restaurant_catalog?(turn),
            do: Model.list(surface_id, heading, found, turn.base_url),
            else: UI.list(surface_id, heading, found, turn.base_url, turn.version, rating: false)

        count =
          if length(found) == 1,
            do: "Here is one place.",
            else: "Here are #{length(found)} places."

        %{text: count <> " Pick one to book a table.", messages: messages}
    end
  end

  # -- events ---------------------------------------------------------------------

  defp event(%{"action" => %{"name" => "book", "context" => context}}, turn) do
    case Restaurants.get(context["restaurantId"]) do
      nil ->
        say("I can't find that restaurant any more.")

      restaurant ->
        calls? = turn.version == "v1.0" and turn.function_calls and restaurant_catalog?(turn)

        messages =
          UI.booking("booking-" <> turn.turn_id, restaurant, turn.version,
            availability: calls? and turn.format == :direct_json,
            ask_client: calls?,
            today: turn.today || Date.utc_today()
          )

        %{text: "Let's book a table at #{restaurant["name"]}.", messages: messages}
    end
  end

  defp event(
         %{"action" => %{"name" => "submit_booking", "surfaceId" => surface_id} = action},
         turn
       ) do
    booking = get_in(action, ["context", "booking"]) || %{}

    if blank?(booking["name"]) or blank?(booking["email"]) do
      say("I need a name and an email address to book the table.")
    else
      Logger.info(
        "booked #{booking["restaurant"]} for #{booking["partySize"]} on #{booking["date"]}"
      )

      %{
        text: "Done! Your table at #{booking["restaurant"]} is booked.",
        messages: UI.confirmation(surface_id, booking, turn.version)
      }
    end
  end

  defp event(%{"action" => %{"name" => "done", "surfaceId" => surface_id}}, turn),
    do: %{text: "Enjoy your meal!", messages: [UI.delete(surface_id, turn.version)]}

  defp event(%{"action" => %{"name" => name}}, _turn),
    do: say("I don't know what to do with \"#{name}\".")

  defp event(%{"callAgentFunction" => %{"functionCallId" => id} = call}, turn),
    do: agent_function(id, call["callFunction"] || %{}, turn)

  defp event(
         %{
           "rendererFunctionResponse" =>
             %{"functionCallId" => "clientinfo:" <> surface_id} = response
         },
         turn
       ) do
    case response do
      %{"value" => %{"timeZone" => zone}} when is_binary(zone) ->
        %{
          text: "Times are in #{zone}.",
          messages: [
            %{
              "version" => turn.version,
              "updateDataModel" => %{
                "surfaceId" => surface_id,
                "path" => "/booking/timeZone",
                "value" => zone
              }
            }
          ]
        }

      _error ->
        say("")
    end
  end

  defp event(%{"rendererFunctionResponse" => _other}, _turn), do: say("")

  defp event(%{"error" => %{"code" => code} = error}, _turn) do
    Logger.warning("renderer reported #{code}: #{error["message"]}")
    say("Sorry, something went wrong on my side (#{code}).")
  end

  defp event(_other, _turn), do: say("")

  # -- agent functions ------------------------------------------------------------

  defp agent_function(
         id,
         %{"@call" => "checkAvailability", "args" => args},
         %__MODULE__{format: :direct_json} = turn
       ) do
    outcome =
      case Restaurants.availability(args["restaurantId"], args["date"], args["partySize"] || 0) do
        {:ok, answer} ->
          %{"value" => answer}

        {:error, reason} ->
          %{"error" => %{"code" => "INVALID_FUNCTION_CALL", "message" => reason}}
      end

    response(id, outcome, turn)
  end

  defp agent_function(id, %{"@call" => name}, %__MODULE__{format: :direct_json} = turn) do
    error = %{
      "code" => "UNKNOWN_FUNCTION",
      "message" => "The agent has no function named #{name}."
    }

    response(id, %{"error" => error}, turn)
  end

  # Express has no notation for function responses.
  defp agent_function(_id, _call, _turn), do: say("This endpoint does not answer function calls.")

  defp response(id, outcome, turn) do
    message = %{
      "version" => turn.version,
      "agentFunctionResponse" => Map.put(outcome, "functionCallId", id)
    }

    %{text: "", messages: [message]}
  end

  defp say(text), do: %{text: text, messages: []}

  defp restaurant_catalog?(%__MODULE__{catalogs: :all}), do: true

  defp restaurant_catalog?(%__MODULE__{catalogs: catalogs}),
    do: RestaurantAgent.Catalogs.restaurant_id() in catalogs

  defp join("", text), do: text
  defp join(text, ""), do: text
  defp join(left, right), do: left <> "\n" <> right

  defp blank?(value), do: not is_binary(value) or String.trim(value) == ""
end

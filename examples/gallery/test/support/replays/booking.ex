defmodule Gallery.Replays.Booking do
  @moduledoc """
  The restaurant agent's conversation (`examples/restaurant_agent`): the
  agent answers over A2A, in process, and a renderer session holding the
  basic and restaurant catalogs shows its surfaces, as the gallery's chat
  page does. Find a restaurant, book a table, change the party size,
  confirm, and close the booking.
  """

  alias A2UIAgent.A2A
  alias A2UICore.Catalog
  alias A2UIPhoenix.Session
  alias Gallery.Replays.Recorder

  @time_zone "Europe/Lisbon"

  @doc "The replay."
  def replay do
    %{
      "id" => "booking",
      "title" => "Book a table",
      "source" => "examples/restaurant_agent",
      "summary" =>
        "The restaurant agent over A2A and a renderer session: actions, agent and renderer functions, two-way bindings.",
      "steps" => Recorder.steps(record())
    }
  end

  defp record do
    session = renderer()
    list = "restaurants-m1"
    booking = "booking-m2"

    {session, said, messages, out} =
      ask(session, [A2A.text_part("Find Italian restaurants")], "m1")

    book = Recorder.button(session, list, "Book a table", 1)

    first = %{
      caption:
        "You ask for Italian restaurants. The agent answers with text and a surface: three cards, each with the restaurant catalog's Rating.",
      user: "Find Italian restaurants",
      said: said,
      entries: entries(messages, out),
      surfaces: surfaces(session),
      next: click(list, book, "Book a table")
    }

    {session, [action]} = Recorder.click(session, list, book)
    {session, said, messages, calls} = tell(session, [action], "m2")

    form = %{
      caption:
        "Book a table sends an action with the restaurant in its context. The agent answers with a booking form and calls the renderer function clientInfo (callRendererFunction); the form's availability line calls the agent function checkAvailability (callAgentFunction).",
      said: said,
      entries: [Recorder.entry(:out, action) | entries(messages, calls)],
      surfaces: surfaces(session),
      next: Recorder.wait_move("The agent answers")
    }

    {session, said, messages, out} = tell(session, calls, "m3")
    party = Recorder.field(session, booking, "Party size")

    answered = %{
      caption:
        "The agent answers both: it writes the renderer's time zone into the data model, and checkAvailability's answer fills the availability line.",
      said: said,
      entries: entries(messages, out),
      surfaces: surfaces(session),
      next: type(booking, party, 10, "Set Party size to 10")
    }

    {session, ten} = change(session, booking, party, 10, "m4")

    ten =
      Map.merge(ten, %{
        caption:
          "A party of ten: the new argument makes a new call to checkAvailability, and the answer says why there is no table.",
        next: type(booking, party, 4, "Set Party size to 4")
      })

    {session, four} = change(session, booking, party, 4, "m5")
    name = Recorder.field(session, booking, "Your name")

    four =
      Map.merge(four, %{
        caption: "A party of four: another call, and a table is free.",
        next: type(booking, name, "Ada", "Type Ada in Your name")
      })

    {session, []} = Recorder.write(session, booking, name, "Ada")
    email = Recorder.field(session, booking, "Email")

    named = %{
      caption:
        "The name goes into the surface's data model, and its checks pass. Typing sends nothing to the agent.",
      surfaces: surfaces(session),
      next: type(booking, email, "ada@example.com", "Type an email address")
    }

    {session, []} = Recorder.write(session, booking, email, "ada@example.com")
    confirm = Recorder.button(session, booking, "Confirm booking")

    mailed = %{
      caption: "The email address too. Every check passes, so Confirm booking turns on.",
      surfaces: surfaces(session),
      next: click(booking, confirm, "Confirm booking")
    }

    {session, [submit]} = Recorder.click(session, booking, confirm)
    {session, said, messages, out} = tell(session, [submit], "m6")
    done = Recorder.button(session, booking, "Done")

    confirmed = %{
      caption:
        "Confirm booking sends the booking, bound from the data model, in the action's context. The agent replaces the form with a confirmation.",
      said: said,
      entries: [Recorder.entry(:out, submit) | entries(messages, out)],
      surfaces: surfaces(session),
      next: click(booking, done, "Done")
    }

    {session, [finish]} = Recorder.click(session, booking, done)
    {session, said, messages, out} = tell(session, [finish], "m7")

    closed = %{
      caption: "Done tells the agent, which deletes the booking surface. The list stays.",
      said: said,
      entries: [Recorder.entry(:out, finish) | entries(messages, out)],
      surfaces: surfaces(session)
    }

    [first, form, answered, ten, four, named, mailed, confirmed, closed]
  end

  # A new party size: the renderer calls the agent function again.
  defp change(session, surface_id, field, value, id) do
    {session, calls} = Recorder.write(session, surface_id, field, value)
    {session, said, messages, out} = tell(session, calls, id)

    {session,
     %{
       said: said,
       entries: Enum.map(calls, &Recorder.entry(:out, &1)) ++ entries(messages, out),
       surfaces: surfaces(session)
     }}
  end

  defp click(surface_id, node, label),
    do: Recorder.click_move("#" <> Recorder.dom_id(surface_id, node), label)

  defp type(surface_id, node, value, text),
    do: Recorder.type_move("#" <> Recorder.dom_id(surface_id, node, "input"), value, text)

  defp entries(messages, out),
    do: Enum.map(messages, &Recorder.entry(:in, &1)) ++ Enum.map(out, &Recorder.entry(:out, &1))

  # A2A: a message/send with the renderer's capabilities and data model in
  # its metadata, answered in process.
  defp ask(session, parts, id) do
    message = %{
      "kind" => "message",
      "messageId" => id,
      "contextId" => "replay",
      "role" => "user",
      "parts" => parts,
      "metadata" => metadata(session)
    }

    body = %{
      "jsonrpc" => "2.0",
      "id" => id,
      "method" => "message/send",
      "params" => %{"message" => message}
    }

    {:reply, response, _extensions} =
      A2A.Server.handle(body, RestaurantAgent.Agent, RestaurantAgent.Agent.options())

    parts = get_in(response, ["result", "status", "message", "parts"]) || []
    said = Enum.join(for(%{"kind" => "text", "text" => text} <- parts, do: text), " ")
    messages = A2A.a2ui_messages(parts)
    {session, out} = Recorder.apply(session, messages)
    {session, said, messages, out}
  end

  defp tell(session, messages, id),
    do: ask(session, Enum.map(messages, &A2A.a2ui_part(&1, &1["version"] || "v1.0")), id)

  defp metadata(session) do
    {:ok, capabilities} =
      A2UICore.Processor.renderer_capabilities(session.processor, versions: ["v1.0"])

    {:ok, data_model} = Session.client_data_model(session)
    %{"a2uiRendererCapabilities" => capabilities, "a2uiRendererDataModel" => data_model}
  end

  defp renderer do
    restaurant =
      Catalog.put_implementations(Gallery.Catalogs.restaurant(), %{"clientInfo" => &client_info/2})

    Session.new([Gallery.Catalogs.basic("v1.0"), restaurant], clock: &Recorder.now/0)
  end

  defp client_info(_args, _context),
    do:
      {:ok,
       %{
         "renderer" => "A2UI gallery (Phoenix LiveView)",
         "locale" => "en-US",
         "timeZone" => @time_zone
       }}

  # The restaurants' pictures, which the agent serves itself, travel
  # inside the replay.
  defp surfaces(session) do
    base = Regex.escape(RestaurantAgent.base_url())
    pattern = ~r{src="#{base}/images/([a-z0-9-]+)\.svg"}

    for {id, html} <- Recorder.surfaces(session) do
      {id,
       Regex.replace(pattern, html, fn _match, restaurant ->
         svg = RestaurantAgent.Restaurants.image(restaurant)
         ~s(src="data:image/svg+xml;base64,#{Base.encode64(svg)}")
       end)}
    end
  end
end

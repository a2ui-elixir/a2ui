defmodule RestaurantAgent.ConversationTest do
  # A whole conversation between the agent (over A2A, in process) and a
  # real renderer session: find, book, check availability, confirm.
  use ExUnit.Case, async: true

  import RestaurantAgent.Test.A2A, only: [answer: 1, text: 1, data: 1]

  alias A2UIAgent.A2A
  alias RestaurantAgent.Test.Renderer

  defp ask(session, parts, id) do
    message = %{
      "kind" => "message",
      "messageId" => id,
      "contextId" => "conversation-1",
      "role" => "user",
      "parts" => parts,
      "metadata" => Renderer.metadata(session)
    }

    body = %{
      "jsonrpc" => "2.0",
      "id" => id,
      "method" => "message/send",
      "params" => %{"message" => message}
    }

    {:reply, response, _} =
      A2A.Server.handle(body, RestaurantAgent.Agent, RestaurantAgent.Agent.options())

    {texts, messages} = answer(response)
    {session, outbound} = Renderer.apply(session, messages)
    {session, texts, outbound}
  end

  defp tell(session, outbound, id), do: ask(session, Enum.map(outbound, &data/1), id)

  test "find a restaurant, book a table and finish" do
    session = Renderer.new()

    {session, ["Here are 3 places." <> _], []} =
      ask(session, [text("Find Italian restaurants")], "m1")

    assert Renderer.surface_ids(session) == ["restaurants-m1"]
    assert "Pizzeria Napoli" in Renderer.texts(session, "restaurants-m1")

    # The second card is Pizzeria Napoli: nearest first.
    {session, [book]} = Renderer.click(session, "restaurants-m1", "Book a table", 1)

    assert book["action"]["context"] == %{
             "restaurantId" => "pizzeria-napoli",
             "name" => "Pizzeria Napoli"
           }

    # The form asks the renderer for clientInfo, and the renderer asks the
    # agent whether a table is free.
    {session, ["Let's book a table at Pizzeria Napoli."], outbound} = tell(session, [book], "m2")

    assert Enum.sort(Enum.map(outbound, &(&1 |> Map.delete("version") |> Map.keys() |> hd()))) ==
             ["callAgentFunction", "rendererFunctionResponse"]

    {session, ["Times are in Europe/Berlin."], []} = tell(session, outbound, "m3")
    texts = Renderer.texts(session, "booking-m2")
    assert "A table for 2 is free at 19:30." in texts
    assert "2 guests" in texts

    # A party of ten is too many: the new arguments make a new call.
    {session, [call]} = Renderer.type(session, "booking-m2", "Party size", 10)
    assert call["callAgentFunction"]["callFunction"]["args"]["partySize"] == 10
    {session, [], []} = tell(session, [call], "m4")

    assert "Pizzeria Napoli seats at most 8 at one table. Call them for a group booking." in Renderer.texts(
             session,
             "booking-m2"
           )

    {session, [call]} = Renderer.type(session, "booking-m2", "Party size", 4)
    {session, [], []} = tell(session, [call], "m5")
    assert "A table for 4 is free at 19:30." in Renderer.texts(session, "booking-m2")

    {session, []} = Renderer.type(session, "booking-m2", "Your name", "Ada")
    {session, []} = Renderer.type(session, "booking-m2", "Email", "ada@example.com")

    {session, [submit]} = Renderer.click(session, "booking-m2", "Confirm booking")
    assert submit["action"]["context"]["booking"]["partySize"] == 4

    {session, ["Done! Your table at Pizzeria Napoli is booked."], []} =
      tell(session, [submit], "m6")

    texts = Renderer.texts(session, "booking-m2")
    assert "Ada, we expect you at Pizzeria Napoli on Saturday, October 17 at 19:30." in texts
    assert "A table for 4." in texts

    {session, [done]} = Renderer.click(session, "booking-m2", "Done")
    {session, ["Enjoy your meal!"], []} = tell(session, [done], "m7")
    assert Renderer.surface_ids(session) == ["restaurants-m1"]
  end
end

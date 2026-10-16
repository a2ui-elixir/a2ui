defmodule RestaurantAgent.TurnTest do
  use ExUnit.Case, async: true

  alias RestaurantAgent.{Restaurants, Turn}

  import RestaurantAgent.Test.A2A, only: [action: 3, keys: 1, restaurant: 0]

  defp respond(fields),
    do: Turn.respond(struct!(Turn, Keyword.merge([today: ~D[2026-10-16]], fields)))

  defp components(%{"createSurface" => %{"components" => components}}), do: components

  describe "text" do
    test "a greeting gets help and no surface" do
      assert %{text: "Hello! Ask me" <> _, messages: []} = respond(text: "hi there")
      assert %{text: "Hello!" <> _, messages: []} = respond(text: "  ")
    end

    test "a cuisine gets the list, written with the macro in v1.0 direct JSON" do
      %{text: text, messages: [create]} = respond(text: "Find Italian restaurants", turn_id: "t1")

      assert text == "Here are 3 places. Pick one to book a table."
      assert create["createSurface"]["surfaceId"] == "restaurants-t1"
      assert Enum.any?(components(create), &(&1["component"] == "RestaurantCard"))
      assert Enum.any?(components(create), &(&1["catalogId"] == restaurant()))
      assert get_in(create, ["createSurface", "dataModel", "count"]) == 3
    end

    test "Express and v0.9 get the list built in code" do
      %{messages: [create]} = respond(text: "japanese", format: :express)
      refute Enum.any?(components(create), &(&1["component"] == "RestaurantCard"))
      refute Enum.any?(components(create), &(&1["component"] == "Rating"))

      %{text: "Here is one place." <> _, messages: messages} =
        respond(text: "mexican", version: "v0.9")

      assert keys(messages) == ["createSurface", "updateComponents", "updateDataModel"]
      assert Enum.all?(messages, &(&1["version"] == "v0.9"))
      assert hd(messages)["createSurface"]["theme"]["agentDisplayName"] == "Restaurant finder"
    end

    test "a request that names no cuisine I know lists every restaurant" do
      %{text: "Here are 8 places." <> _, messages: [create]} = respond(text: "somewhere to eat")
      assert hd(tl(components(create)))["text"] == "## Restaurants near you"
    end
  end

  describe "actions" do
    test "book opens the form, asks for availability and for the client's time zone" do
      event = action("book", "restaurants-t1", %{"restaurantId" => "sakura"})
      %{text: text, messages: [create, call]} = respond(events: [event], turn_id: "t2")

      assert text == "Let's book a table at Sakura."
      assert create["createSurface"]["surfaceId"] == "booking-t2"
      assert create["createSurface"]["sendDataModel"] == true
      assert create["createSurface"]["dataModel"]["booking"]["today"] == "2026-10-16"

      assert Enum.any?(
               components(create),
               &match?(%{"text" => %{"@call" => "checkAvailability"}}, &1)
             )

      assert %{"callRendererFunction" => %{"functionCallId" => "clientinfo:booking-t2"}} = call
    end

    test "Express leaves availability out, v0.9 the function calls too" do
      event = action("book", "r", %{"restaurantId" => "sakura"})

      %{messages: [create, _call]} = respond(events: [event], format: :express)

      refute Enum.any?(
               components(create),
               &match?(%{"text" => %{"@call" => "checkAvailability"}}, &1)
             )

      %{messages: messages} = respond(events: [event], version: "v0.9")
      assert keys(messages) == ["createSurface", "updateComponents", "updateDataModel"]
    end

    test "booking an unknown restaurant, or an unknown action, is answered in text" do
      assert %{messages: [], text: "I can't find" <> _} =
               respond(events: [action("book", "r", %{"restaurantId" => "nowhere"})])

      assert %{messages: [], text: "I don't know what to do with \"dance\"."} =
               respond(events: [action("dance", "r", %{})])
    end

    test "submitting a complete booking confirms it" do
      booking = %{
        "restaurant" => "Sakura",
        "name" => "Ada",
        "email" => "ada@example.com",
        "date" => "2026-10-17T19:30",
        "partySize" => 3
      }

      %{text: text, messages: messages} =
        respond(events: [action("submit_booking", "booking-t2", %{"booking" => booking})])

      assert text == "Done! Your table at Sakura is booked."
      assert keys(messages) == ["updateComponents", "updateDataModel"]

      assert Enum.all?(
               messages,
               &(get_in(&1, [&1 |> Map.delete("version") |> Map.keys() |> hd(), "surfaceId"]) ==
                   "booking-t2")
             )

      assert %{messages: [], text: "I need a name" <> _} =
               respond(
                 events: [
                   action("submit_booking", "booking-t2", %{"booking" => %{"name" => " "}})
                 ]
               )
    end

    test "done takes the surface away" do
      assert %{messages: [%{"deleteSurface" => %{"surfaceId" => "booking-t2"}}]} =
               respond(events: [action("done", "booking-t2", %{})])
    end
  end

  describe "function calls" do
    defp call(name, args) do
      %{
        "version" => "v1.0",
        "callAgentFunction" => %{
          "surfaceId" => "booking-t2",
          "functionCallId" => "call-7",
          "callFunction" => %{"@call" => name, "args" => args}
        }
      }
    end

    test "checkAvailability is answered with agentFunctionResponse" do
      args = %{"restaurantId" => "sakura", "date" => "2026-10-17T19:30", "partySize" => 2}

      assert %{
               messages: [
                 %{
                   "agentFunctionResponse" => %{
                     "functionCallId" => "call-7",
                     "value" => "A table for 2 is free at 19:30."
                   }
                 }
               ]
             } =
               respond(events: [call("checkAvailability", args)])

      assert %{
               messages: [
                 %{"agentFunctionResponse" => %{"error" => %{"code" => "INVALID_FUNCTION_CALL"}}}
               ]
             } =
               respond(events: [call("checkAvailability", %{args | "date" => "soon"})])

      assert %{
               messages: [
                 %{"agentFunctionResponse" => %{"error" => %{"code" => "UNKNOWN_FUNCTION"}}}
               ]
             } =
               respond(events: [call("teleport", %{})])

      assert %{messages: [], text: "This endpoint does not answer function calls."} =
               respond(events: [call("checkAvailability", args)], format: :express)
    end

    test "the client's time zone goes into the booking form" do
      response = %{
        "version" => "v1.0",
        "rendererFunctionResponse" => %{
          "functionCallId" => "clientinfo:booking-t2",
          "value" => %{"timeZone" => "Europe/Oslo", "locale" => "nb-NO"}
        }
      }

      assert %{
               text: "Times are in Europe/Oslo.",
               messages: [
                 %{
                   "updateDataModel" => %{
                     "surfaceId" => "booking-t2",
                     "path" => "/booking/timeZone",
                     "value" => "Europe/Oslo"
                   }
                 }
               ]
             } = respond(events: [response])

      failed =
        put_in(response, ["rendererFunctionResponse"], %{
          "functionCallId" => "clientinfo:b",
          "error" => %{"code" => "X", "message" => "no"}
        })

      assert %{messages: [], text: ""} = respond(events: [failed])

      assert %{messages: [], text: ""} =
               respond(
                 events: [
                   %{"rendererFunctionResponse" => %{"functionCallId" => "other", "value" => 1}}
                 ]
               )
    end

    test "without the restaurant catalog there are no ratings and no function calls" do
      basic = [RestaurantAgent.Test.A2A.basic()]

      %{messages: [create]} = respond(text: "italian", catalogs: basic)
      refute Enum.any?(components(create), &(&1["component"] in ["Rating", "RestaurantCard"]))

      %{messages: [create]} =
        respond(events: [action("book", "r", %{"restaurantId" => "sakura"})], catalogs: basic)

      refute inspect(create) =~ "checkAvailability"
    end

    test "a transport that cannot answer function calls gets a form that makes none" do
      event = action("book", "r", %{"restaurantId" => "sakura"})
      %{messages: [create]} = respond(events: [event], function_calls: false)

      refute Enum.any?(
               components(create),
               &match?(%{"text" => %{"@call" => "checkAvailability"}}, &1)
             )
    end

    test "errors are acknowledged, other events ignored" do
      assert %{text: "Sorry, something went wrong on my side (INTEGRITY_ERROR).", messages: []} =
               respond(
                 events: [
                   %{
                     "version" => "v1.0",
                     "error" => %{"code" => "INTEGRITY_ERROR", "message" => "x"}
                   }
                 ]
               )

      assert %{text: "", messages: []} =
               respond(events: [%{"version" => "v1.0", "something" => %{}}])
    end
  end

  describe "availability" do
    test "large parties, Friday evenings and free tables" do
      assert {:ok, "Trattoria Roma seats at most 8" <> _} =
               Restaurants.availability("trattoria-roma", "2026-10-17T19:30", 9)

      assert {:ok, "Fully booked on Friday evening." <> _} =
               Restaurants.availability("trattoria-roma", "2026-10-16T20:00", 2)

      assert {:ok, "A table for 4 is free at 19:00."} =
               Restaurants.availability("trattoria-roma", "2026-10-18", 4)

      assert {:ok, "A table for 2 is free at 12:15."} =
               Restaurants.availability("sakura", "2026-10-18T12:15:00", 2)

      assert {:error, "Unknown restaurant: x"} = Restaurants.availability("x", "2026-10-18", 2)
      assert {:error, "Not a date: 5"} = Restaurants.availability("sakura", 5, 2)
    end

    test "every restaurant has a picture" do
      for restaurant <- Restaurants.all(),
          do: assert(Restaurants.image(restaurant["id"]) =~ "<svg")

      assert Restaurants.image("nowhere") == nil
    end
  end
end

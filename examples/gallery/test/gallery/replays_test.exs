defmodule Gallery.ReplaysTest do
  # The landing page's replays (site/priv/replays.json) are recordings of
  # these examples; they must match a fresh recording.
  use ExUnit.Case, async: false

  @site Path.expand("../../../../site", __DIR__)

  setup_all do
    %{replays: Gallery.Replays.all()}
  end

  test "the site holds a fresh recording and the renderer's stylesheet", %{replays: replays} do
    targets = Gallery.Replays.targets(@site)

    assert File.read!(targets.json) == Gallery.Replays.json(replays),
           "the replays changed: run mix gallery.replays"

    assert File.read!(targets.stylesheet) == File.read!(Gallery.Replays.stylesheet()),
           "the renderer's stylesheet changed: run mix gallery.replays"
  end

  test "what each move clicks or types into is on the surfaces of its step", %{replays: replays} do
    for replay <- replays do
      replay["steps"]
      |> Enum.with_index()
      |> Enum.reduce(%{}, fn {step, index}, shown ->
        shown = shown |> Map.merge(step["surfaces"]) |> Map.take(step["order"])

        with %{"target" => target} <- step["next"] do
          page = shown |> Map.values() |> Enum.join() |> LazyHTML.from_fragment()

          assert Enum.count(LazyHTML.query(page, target)) == 1,
                 "#{replay["id"]} step #{index}: no single #{target}"
        end

        shown
      end)
    end
  end

  test "the booking is the restaurant agent's conversation", %{replays: replays} do
    booking = Enum.find(replays, &(&1["id"] == "booking"))
    said = for step <- booking["steps"], step["said"], do: step["said"]

    assert said == [
             "Here are 3 places. Pick one to book a table.",
             "Let's book a table at Pizzeria Napoli.",
             "Times are in Europe/Lisbon.",
             "Done! Your table at Pizzeria Napoli is booked.",
             "Enjoy your meal!"
           ]

    html = booking["steps"] |> Enum.flat_map(&Map.values(&1["surfaces"])) |> Enum.join()
    assert html =~ "Ada, we expect you at Pizzeria Napoli on Saturday, October 17 at 19:30."
    refute html =~ RestaurantAgent.base_url()
  end
end

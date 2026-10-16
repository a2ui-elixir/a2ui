defmodule Site.ReplaysTest do
  use ExUnit.Case, async: true

  alias Site.Replays

  defp replay(id), do: Enum.find(Replays.all(), &(&1["id"] == id))

  defp last(replay), do: Replays.view(replay, length(replay["steps"]) - 1)

  test "every replay has steps, and each move names what the user does" do
    for replay <- Replays.all() do
      assert [_ | _] = replay["steps"]

      for step <- replay["steps"], move = step["next"] do
        assert move["do"] in ~w(click type wait)
        assert is_binary(move["text"])
        if move["do"] != "wait", do: assert(is_binary(move["target"]))
      end
    end
  end

  test "the booking ends with the list, the booking surface deleted and the agent's goodbye" do
    view = last(replay("booking"))

    assert Map.keys(view.surfaces) == ["restaurants-m1"]
    assert %{type: :deleted, id: "booking-m2"} in view.chat
    assert List.last(view.chat) == %{type: :agent, text: "Enjoy your meal!"}

    actions = for %{type: :action} = item <- view.chat, do: {item.label, item.name}

    assert actions == [
             {"Book a table", "book"},
             {"Confirm booking", "submit_booking"},
             {"Done", "done"}
           ]
  end

  test "a streamed replay holds the whole answer, and its text continues its bubbles" do
    replay = replay("streaming")
    view = last(replay)

    assert view.stream == Enum.map_join(replay["steps"], & &1["chunk"])
    assert view.stream =~ "<a2ui-json>"

    texts = for %{type: :agent, text: text} <- view.chat, do: text

    assert texts == [
             "Here is the week ahead in Lisbon. I'll fill in the details as they come.",
             "Anything else you'd like to know?"
           ]

    assert [%{type: :agent}, %{type: :surface, id: "forecast"}, %{type: :agent}] = view.chat
  end

  test "a view keeps the latest caption and the messages up to its step" do
    replay = replay("forms")
    steps = replay["steps"]

    for index <- 0..(length(steps) - 1) do
      view = Replays.view(replay, index)

      expected =
        for {step, at} <- Enum.with_index(Enum.take(steps, index + 1)),
            entry <- step["entries"] || [],
            do: {entry, at}

      assert view.entries == expected

      assert view.caption ==
               Enum.take(steps, index + 1)
               |> Enum.map(& &1["caption"])
               |> Enum.reject(&is_nil/1)
               |> List.last()
    end
  end

  test "the JSON for the page escapes every <" do
    json = Replays.json()
    refute json =~ "<"
    assert Jason.decode!(json)["replays"] |> length() == length(Replays.all())
  end
end

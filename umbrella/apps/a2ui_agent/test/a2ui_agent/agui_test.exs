defmodule A2UIAgent.AGUITest do
  use ExUnit.Case, async: true

  alias A2UIAgent.AGUI

  doctest A2UIAgent.AGUI

  defp message(action, surface_id, body \\ %{}),
    do: %{"version" => "v1.0", action => Map.put(body, "surfaceId", surface_id)}

  test "snapshots carry every message of their surface so far" do
    create = message("createSurface", "s1", %{"catalogId" => "basic"})
    components = message("updateComponents", "s1", %{"components" => []})
    other = message("createSurface", "s2", %{"catalogId" => "basic"})

    {[first], surfaces} = AGUI.snapshots(%{}, [create])
    assert first == AGUI.activity_snapshot("a2ui-surface-s1", [create])

    {events, surfaces} = AGUI.snapshots(surfaces, [other, components, %{"version" => "v1.0"}])

    assert Enum.map(events, &{&1["messageId"], AGUI.a2ui_messages(&1)}) == [
             {"a2ui-surface-s2", [other]},
             {"a2ui-surface-s1", [create, components]}
           ]

    assert surfaces == %{"s1" => [create, components], "s2" => [other]}
  end

  test "a deleted surface starts over" do
    create = message("createSurface", "s1", %{"catalogId" => "basic"})
    delete = message("deleteSurface", "s1")

    {_events, surfaces} = AGUI.snapshots(%{}, [create])
    {[event], surfaces} = AGUI.snapshots(surfaces, [delete])

    assert AGUI.a2ui_messages(event) == [create, delete]
    assert surfaces == %{}
  end

  test "reads the messages of A2UI snapshots only" do
    assert AGUI.a2ui_messages(AGUI.activity_snapshot("x", [%{"a" => 1}])) == [%{"a" => 1}]

    assert AGUI.a2ui_messages(%{
             "type" => "ACTIVITY_SNAPSHOT",
             "activityType" => "PLAN",
             "content" => %{}
           }) ==
             nil

    assert AGUI.a2ui_messages(%{"type" => "TEXT_MESSAGE_END"}) == nil
  end

  test "a user action becomes an action message" do
    input = %{
      "forwardedProps" => %{
        "a2uiAction" => %{"userAction" => %{"type" => "x", "name" => "go", "surfaceId" => "s"}}
      }
    }

    assert AGUI.user_action(input, "v0.9") == %{
             "version" => "v0.9",
             "action" => %{"name" => "go", "surfaceId" => "s"}
           }

    assert AGUI.user_action(%{"messages" => []}) == nil
    assert AGUI.user_action(%{"forwardedProps" => %{"a2uiAction" => %{}}}) == nil
  end

  test "text and run events" do
    assert AGUI.text_message("m1", "") == []

    assert [
             %{"type" => "TEXT_MESSAGE_START", "messageId" => "m1", "role" => "assistant"},
             %{"type" => "TEXT_MESSAGE_CONTENT", "messageId" => "m1", "delta" => "Hi"},
             %{"type" => "TEXT_MESSAGE_END", "messageId" => "m1"}
           ] = AGUI.text_message("m1", "Hi")

    assert AGUI.run_started("t", "r") == %{
             "type" => "RUN_STARTED",
             "threadId" => "t",
             "runId" => "r"
           }

    assert AGUI.run_finished("t", "r") == %{
             "type" => "RUN_FINISHED",
             "threadId" => "t",
             "runId" => "r"
           }

    assert AGUI.run_error("boom") == %{"type" => "RUN_ERROR", "message" => "boom"}
    assert AGUI.run_error("boom", "E1")["code"] == "E1"
  end

  test "events are encoded as server-sent events" do
    event = AGUI.run_started("t", "r")
    assert IO.iodata_to_binary(AGUI.encode(event)) == "data: " <> Jason.encode!(event) <> "\n\n"
  end
end

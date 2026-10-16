defmodule A2UIAgent.AGUI do
  @moduledoc """
  Carries A2UI over [AG-UI](https://docs.ag-ui.com), the event protocol
  between agents and their front ends, the way AG-UI's A2UI middleware
  and the renderers built on it (CopilotKit, assistant-ui) do. A2UI does
  not define this binding itself.

  A surface travels as `ACTIVITY_SNAPSHOT` events of the activity type
  `a2ui-surface`, whose content holds the surface's A2UI messages under
  `a2ui_operations`. A snapshot replaces the activity it names, so each
  one carries every message of its surface so far; `snapshots/2` keeps
  them per surface:

      {events, surfaces} = A2UIAgent.AGUI.snapshots(%{}, messages)
      Enum.map(events, &A2UIAgent.AGUI.encode/1)

  A user's action starts a new run with no new user message; it arrives
  in the run's input, under `forwardedProps.a2uiAction.userAction`, which
  `user_action/2` reads.

  AG-UI carries no renderer capabilities: the agent writes for the
  catalogs it is configured with (`A2UIAgent.Generator.create_processor/3`
  with `nil` capabilities activates them all).
  """

  @moduledoc since: "0.1.0"

  @activity_type "a2ui-surface"
  @operations_key "a2ui_operations"
  @surface_actions ["createSurface", "updateComponents", "updateDataModel", "deleteSurface"]

  @typedoc "Messages so far, by surface id."
  @type surfaces :: %{optional(String.t()) => [map()]}

  @doc "The activity type of A2UI surfaces: `#{@activity_type}`."
  @spec activity_type() :: String.t()
  def activity_type, do: @activity_type

  @doc """
  An `ACTIVITY_SNAPSHOT` event holding `messages`, the whole state of
  the activity `message_id`.

      iex> A2UIAgent.AGUI.activity_snapshot("a2ui-surface-s1", [])
      %{
        "type" => "ACTIVITY_SNAPSHOT",
        "messageId" => "a2ui-surface-s1",
        "activityType" => "a2ui-surface",
        "content" => %{"a2ui_operations" => []},
        "replace" => true
      }
  """
  @spec activity_snapshot(String.t(), [map()]) :: map()
  def activity_snapshot(message_id, messages) when is_binary(message_id) and is_list(messages) do
    %{
      "type" => "ACTIVITY_SNAPSHOT",
      "messageId" => message_id,
      "activityType" => @activity_type,
      "content" => %{@operations_key => messages},
      "replace" => true
    }
  end

  @doc """
  Adds `messages` to `surfaces` and returns a snapshot for each surface
  they touch, in the order first touched, with the activity id
  `a2ui-surface-<surfaceId>`. A surface whose messages end with its
  `deleteSurface` is dropped after its snapshot, so that it starts over
  if it is created again. Messages that name no surface are left out.
  """
  @spec snapshots(surfaces(), [map()]) :: {[map()], surfaces()}
  def snapshots(surfaces, messages) when is_map(surfaces) and is_list(messages) do
    {surfaces, touched} =
      Enum.reduce(messages, {surfaces, []}, fn message, {surfaces, touched} ->
        case surface_id(message) do
          nil -> {surfaces, touched}
          id -> {Map.update(surfaces, id, [message], &(&1 ++ [message])), touched ++ [id]}
        end
      end)

    ids = Enum.uniq(touched)
    events = Enum.map(ids, &activity_snapshot("a2ui-surface-" <> &1, Map.fetch!(surfaces, &1)))
    {events, Map.reject(surfaces, fn {_id, list} -> deleted?(List.last(list)) end)}
  end

  defp surface_id(%{} = message) do
    Enum.find_value(@surface_actions, fn action ->
      case message[action] do
        %{"surfaceId" => id} when is_binary(id) -> id
        _other -> nil
      end
    end)
  end

  defp surface_id(_message), do: nil

  defp deleted?(message), do: is_map(message) and Map.has_key?(message, "deleteSurface")

  @doc """
  The A2UI messages of an event: those of an `a2ui-surface` activity
  snapshot, else `nil`.
  """
  @spec a2ui_messages(map()) :: [map()] | nil
  def a2ui_messages(%{
        "type" => "ACTIVITY_SNAPSHOT",
        "activityType" => @activity_type,
        "content" => %{@operations_key => messages}
      })
      when is_list(messages),
      do: messages

  def a2ui_messages(%{}), do: nil

  @doc """
  The user action a run's input carries, as an A2UI `action` message of
  `version`, or `nil` when the run was started otherwise.

      iex> A2UIAgent.AGUI.user_action(%{"forwardedProps" => %{"a2uiAction" => %{"userAction" =>
      ...>   %{"name" => "book", "surfaceId" => "s", "context" => %{}}}}})
      %{"version" => "v1.0", "action" => %{"name" => "book", "surfaceId" => "s", "context" => %{}}}
  """
  @spec user_action(map(), String.t()) :: map() | nil
  def user_action(%{} = run_input, version \\ "v1.0") do
    case get_in(run_input, ["forwardedProps", "a2uiAction", "userAction"]) do
      %{} = action -> %{"version" => version, "action" => Map.delete(action, "type")}
      _none -> nil
    end
  end

  @doc """
  The events of an assistant message with `text`: `TEXT_MESSAGE_START`,
  `TEXT_MESSAGE_CONTENT` and `TEXT_MESSAGE_END`. Empty text has no
  events, since a content event needs a non-empty delta.
  """
  @spec text_message(String.t(), String.t()) :: [map()]
  def text_message(_message_id, ""), do: []

  def text_message(message_id, text) when is_binary(text) do
    [
      %{"type" => "TEXT_MESSAGE_START", "messageId" => message_id, "role" => "assistant"},
      %{"type" => "TEXT_MESSAGE_CONTENT", "messageId" => message_id, "delta" => text},
      %{"type" => "TEXT_MESSAGE_END", "messageId" => message_id}
    ]
  end

  @doc "A `RUN_STARTED` event."
  @spec run_started(String.t(), String.t()) :: map()
  def run_started(thread_id, run_id),
    do: %{"type" => "RUN_STARTED", "threadId" => thread_id, "runId" => run_id}

  @doc "A `RUN_FINISHED` event."
  @spec run_finished(String.t(), String.t()) :: map()
  def run_finished(thread_id, run_id),
    do: %{"type" => "RUN_FINISHED", "threadId" => thread_id, "runId" => run_id}

  @doc "A `RUN_ERROR` event, with an optional code."
  @spec run_error(String.t(), String.t() | nil) :: map()
  def run_error(message, code \\ nil) do
    event = %{"type" => "RUN_ERROR", "message" => message}
    if code, do: Map.put(event, "code", code), else: event
  end

  @doc """
  An event as AG-UI's HTTP binding sends it: one server-sent event whose
  data is the event's JSON.
  """
  @spec encode(map()) :: iodata()
  def encode(%{"type" => _} = event), do: ["data: ", Jason.encode_to_iodata!(event), "\n\n"]
end

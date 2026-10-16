defmodule RestaurantAgent.AGUIServer do
  @moduledoc """
  The agent over AG-UI's HTTP binding: a `POST` of a `RunAgentInput`
  answered with server-sent events, following the conventions of AG-UI's
  A2UI middleware (`A2UIAgent.AGUI`).

  The run's last user message is the request; a run that starts with an
  A2UI action (in the input's `forwardedProps`) answers the action. Each
  surface is an activity whose snapshot carries all its messages so far;
  the renderer sends those back in `state.a2uiSurfaces`, so the agent
  extends them without keeping state itself. Only actions travel back,
  so the surfaces make no function calls.
  """

  require Logger

  alias A2UIAgent.AGUI
  alias RestaurantAgent.Turns

  @doc "The events of a run, in order."
  @spec run(map()) :: [map()]
  def run(%{} = input) do
    thread_id = input["threadId"] || "thread-1"
    run_id = input["runId"] || "run-#{System.unique_integer([:positive])}"
    surfaces = surfaces(input)
    events = List.wrap(AGUI.user_action(input))
    text = if events == [], do: last_user_text(input), else: ""
    Logger.info("agui run #{run_id} #{if events == [], do: inspect(text), else: "action"}")

    case Turns.answer(text, events, capabilities(input), turn_id: run_id, function_calls: false) do
      {:ok, answer} ->
        {snapshots, _surfaces} = AGUI.snapshots(surfaces, answer.messages)

        [AGUI.run_started(thread_id, run_id)] ++
          AGUI.text_message("msg-" <> run_id, answer.text) ++
          snapshots ++ [AGUI.run_finished(thread_id, run_id)]

      {:error, reason} ->
        [AGUI.run_started(thread_id, run_id), AGUI.run_error(reason)]
    end
  end

  defp last_user_text(input) do
    (input["messages"] || [])
    |> Enum.filter(&(&1["role"] == "user"))
    |> List.last()
    |> case do
      %{"content" => content} when is_binary(content) -> content
      _none -> ""
    end
  end

  # The surfaces the renderer holds, by id, as their message lists.
  defp surfaces(input) do
    case get_in(input, ["state", "a2uiSurfaces"]) do
      %{} = surfaces -> surfaces
      _none -> %{}
    end
  end

  defp capabilities(input), do: get_in(input, ["forwardedProps", "a2uiRendererCapabilities"])
end

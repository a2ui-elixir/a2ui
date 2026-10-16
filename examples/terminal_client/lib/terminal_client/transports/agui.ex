defmodule TerminalClient.Transports.AGUI do
  @moduledoc """
  AG-UI's HTTP binding: each request is a run (`RunAgentInput`) answered
  with server-sent events. Text is a user message; an action starts a run
  of its own, in `forwardedProps.a2uiAction`.

  Each surface arrives as activity snapshots holding all its messages so
  far. The transport keeps them, sends them back in the run's `state`
  (so the agent can extend them), and hands the renderer only the
  messages it has not seen.
  """

  @behaviour TerminalClient.Transport

  alias A2UIAgent.AGUI
  alias TerminalClient.SSE

  @impl true
  def connect(url, _options) do
    {:ok,
     %{
       url: url,
       thread_id: "thread-#{System.unique_integer([:positive])}",
       messages: [],
       surfaces: %{},
       runs: 0
     }}
  end

  @impl true
  def supports?(message), do: Map.has_key?(message, "action")

  @impl true
  def request(state, inputs, metadata, on_output) do
    Enum.reduce_while(inputs, {:ok, state, []}, fn input, {:ok, state, outputs} ->
      case run(state, input, metadata) do
        {:ok, state, found} ->
          Enum.each(found, on_output)
          {:cont, {:ok, state, outputs ++ found}}

        {:error, reason} ->
          {:halt, {:error, reason}}
      end
    end)
  end

  defp run(state, input, metadata) do
    state = %{state | runs: state.runs + 1}
    run_id = "run-#{state.runs}-#{System.unique_integer([:positive])}"
    {messages, forwarded} = input(state, input)

    body = %{
      "threadId" => state.thread_id,
      "runId" => run_id,
      "messages" => messages,
      "tools" => [],
      "context" => [],
      "state" => %{"a2uiSurfaces" => state.surfaces},
      "forwardedProps" =>
        Map.put(forwarded, "a2uiRendererCapabilities", metadata["a2uiRendererCapabilities"])
    }

    case Req.post(state.url,
           json: body,
           receive_timeout: 60_000,
           retry: false,
           decode_body: false
         ) do
      {:ok, %{status: 200, body: text}} ->
        {events, _rest} = SSE.split(text)
        events = for %{"data" => json} <- events, do: Jason.decode!(json)
        read(%{state | messages: messages}, events)

      {:ok, response} ->
        {:error, "HTTP #{response.status}"}

      {:error, error} ->
        {:error, Exception.message(error)}
    end
  end

  defp input(state, {:text, text}) do
    message = %{"id" => "user-#{state.runs}", "role" => "user", "content" => text}
    {state.messages ++ [message], %{}}
  end

  defp input(state, {:message, %{"action" => action}}),
    do: {state.messages, %{"a2uiAction" => %{"userAction" => action}}}

  defp read(state, events) do
    Enum.reduce_while(events, {:ok, state, []}, fn event, {:ok, state, outputs} ->
      case event do
        %{"type" => "TEXT_MESSAGE_CONTENT", "delta" => delta} ->
          {:cont, {:ok, state, outputs ++ [{:text, delta}]}}

        %{"type" => "ACTIVITY_SNAPSHOT", "messageId" => "a2ui-surface-" <> surface_id} ->
          {state, messages} = snapshot(state, surface_id, AGUI.a2ui_messages(event) || [])
          {:cont, {:ok, state, outputs ++ [{:a2ui, messages}]}}

        %{"type" => "RUN_ERROR", "message" => message} ->
          {:halt, {:error, message}}

        _other ->
          {:cont, {:ok, state, outputs}}
      end
    end)
  end

  # A snapshot that extends what the renderer has brings only the new
  # messages; any other replaces the surface.
  defp snapshot(state, surface_id, messages) do
    previous = Map.get(state.surfaces, surface_id, [])

    new =
      if List.starts_with?(messages, previous),
        do: Enum.drop(messages, length(previous)),
        else: [%{"version" => "v1.0", "deleteSurface" => %{"surfaceId" => surface_id}} | messages]

    surfaces =
      if Enum.any?(new, &Map.has_key?(&1, "deleteSurface")) and
           match?(%{"deleteSurface" => _}, List.last(messages)),
         do: Map.delete(state.surfaces, surface_id),
         else: Map.put(state.surfaces, surface_id, messages)

    {%{state | surfaces: surfaces}, new}
  end
end

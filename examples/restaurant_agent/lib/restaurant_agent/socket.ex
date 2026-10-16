defmodule RestaurantAgent.Socket do
  @moduledoc """
  The agent over a WebSocket: a bidirectional session where every frame
  is one JSON object.

  The renderer sends:

    * `{"metadata": {"a2uiRendererCapabilities": ...}}` — its
      capabilities, kept for the session (also accepted with any frame);
    * `{"text": "..."}` — what the user typed;
    * `{"message": {...}}` — an A2UI message: an `action`, a
      `callAgentFunction`, a `rendererFunctionResponse` or an `error`.

  The agent answers each with a `{"text": "..."}` frame when it has
  something to say, one frame per A2UI message, and `{"done": true}`.
  """

  @behaviour WebSock

  require Logger

  alias RestaurantAgent.Turns

  @impl true
  def init(_options), do: {:ok, %{capabilities: nil}}

  @impl true
  def handle_in({json, opcode: :text}, state) do
    case Jason.decode(json) do
      {:ok, %{} = frame} -> answer(frame, remember(frame, state))
      _other -> {:push, {:text, Jason.encode!(%{"error" => "Frames are JSON objects."})}, state}
    end
  end

  def handle_in({_binary, opcode: :binary}, state),
    do: {:push, {:text, Jason.encode!(%{"error" => "Frames are text."})}, state}

  @impl true
  def handle_info(_message, state), do: {:ok, state}

  defp remember(%{"metadata" => %{"a2uiRendererCapabilities" => %{} = capabilities}}, state),
    do: %{state | capabilities: capabilities}

  defp remember(_frame, state), do: state

  defp answer(%{"text" => text}, state) when is_binary(text), do: reply(text, [], state)
  defp answer(%{"message" => %{} = message}, state), do: reply("", [message], state)
  defp answer(%{"metadata" => _metadata}, state), do: {:push, frame(%{"ready" => true}), state}

  defp answer(_frame, state),
    do: {:push, frame(%{"error" => "Send text, a message or metadata."}), state}

  defp reply(text, events, state) do
    Logger.info("ws #{if events == [], do: inspect(text), else: "message"}")

    frames =
      case Turns.answer(text, events, state.capabilities) do
        {:ok, answer} ->
          said = if answer.text == "", do: [], else: [%{"text" => answer.text}]
          said ++ answer.messages ++ [%{"done" => true}]

        {:error, reason} ->
          [%{"error" => reason}, %{"done" => true}]
      end

    {:push, Enum.map(frames, &frame/1), state}
  end

  defp frame(value), do: {:text, Jason.encode!(value)}
end

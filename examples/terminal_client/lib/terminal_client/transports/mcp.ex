defmodule TerminalClient.Transports.MCP do
  @moduledoc """
  MCP over HTTP: `initialize` with the renderer's capabilities, then a
  tool call per request. Text calls `find_restaurants`; actions and
  errors call `a2ui_action` and `a2ui_error`. The A2UI messages come
  back in embedded resources of the tool results.
  """

  @behaviour TerminalClient.Transport

  @impl true
  def connect(url, _options) do
    state = %{url: url, next_id: 1}

    with {:ok, state, _result} <-
           rpc(state, "initialize", %{
             "protocolVersion" => "2025-06-18",
             "clientInfo" => %{"name" => "terminal-client"},
             "capabilities" => %{}
           }) do
      Req.post(url,
        json: %{"jsonrpc" => "2.0", "method" => "notifications/initialized"},
        retry: false
      )

      {:ok, state}
    end
  end

  @impl true
  def supports?(message), do: Map.has_key?(message, "action") or Map.has_key?(message, "error")

  @impl true
  def request(state, inputs, metadata, on_output) do
    meta = %{
      "a2ui" => %{
        "clientCapabilities" =>
          metadata["a2uiRendererCapabilities"] || metadata["a2uiClientCapabilities"]
      }
    }

    Enum.reduce_while(inputs, {:ok, state, []}, fn input, {:ok, state, outputs} ->
      {name, arguments} = tool(input)

      case rpc(state, "tools/call", %{"name" => name, "arguments" => arguments, "_meta" => meta}) do
        {:ok, state, result} ->
          found = outputs(result)
          Enum.each(found, on_output)
          {:cont, {:ok, state, outputs ++ found}}

        {:error, reason} ->
          {:halt, {:error, reason}}
      end
    end)
  end

  defp tool({:text, text}), do: {"find_restaurants", %{"query" => text}}
  defp tool({:message, %{"action" => action}}), do: {"a2ui_action", action}
  defp tool({:message, %{"error" => error}}), do: {"a2ui_error", error}

  defp outputs(result) do
    texts = for %{"type" => "text", "text" => text} <- result["content"] || [], do: {:text, text}
    {:ok, messages} = A2UIAgent.MCP.a2ui_messages(result)
    if messages == [], do: texts, else: texts ++ [{:a2ui, messages}]
  end

  defp rpc(state, method, params) do
    body = %{"jsonrpc" => "2.0", "id" => state.next_id, "method" => method, "params" => params}
    state = %{state | next_id: state.next_id + 1}

    case Req.post(state.url, json: body, receive_timeout: 60_000, retry: false) do
      {:ok, %{body: %{"result" => result}}} -> {:ok, state, result}
      {:ok, %{body: %{"error" => error}}} -> {:error, error["message"]}
      {:ok, response} -> {:error, "HTTP #{response.status}"}
      {:error, error} -> {:error, Exception.message(error)}
    end
  end
end

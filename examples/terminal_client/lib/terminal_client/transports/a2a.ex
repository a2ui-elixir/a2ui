defmodule TerminalClient.Transports.A2A do
  @moduledoc """
  A2A's JSON-RPC binding: `message/send`, or `message/stream` (option
  `stream: true`) whose server-sent events bring the parts as the agent
  writes them. The A2UI extension is requested in the `X-A2A-Extensions`
  header; the conversation keeps the `contextId` the agent gives.
  """

  @behaviour TerminalClient.Transport

  alias A2UIAgent.A2A
  alias TerminalClient.SSE

  @impl true
  def connect(url, options) do
    {:ok,
     %{
       url: url,
       stream: Keyword.get(options, :stream, false),
       version: Keyword.get(options, :version, "v1.0"),
       context_id: nil,
       next_id: 1
     }}
  end

  @impl true
  def supports?(_message), do: true

  @impl true
  def request(state, inputs, metadata, on_output) do
    method = if state.stream, do: "message/stream", else: "message/send"

    message =
      %{
        "kind" => "message",
        "messageId" => "m#{state.next_id}-#{System.unique_integer([:positive])}",
        "role" => "user",
        "parts" => Enum.map(inputs, &part(&1, state.version)),
        "metadata" => metadata
      }
      |> then(&if state.context_id, do: Map.put(&1, "contextId", state.context_id), else: &1)

    body = %{
      "jsonrpc" => "2.0",
      "id" => state.next_id,
      "method" => method,
      "params" => %{"message" => message}
    }

    headers = [
      {"x-a2a-extensions", A2A.extension_uri(if state.version == "v1.0", do: "1.0", else: "0.9")}
    ]

    state = %{state | next_id: state.next_id + 1}

    if state.stream,
      do: stream(state, body, headers, on_output),
      else: send_message(state, body, headers, on_output)
  end

  defp part({:text, text}, _version), do: A2A.text_part(text)
  defp part({:message, message}, version), do: A2A.a2ui_part(message, version)

  defp send_message(state, body, headers, on_output) do
    case Req.post(state.url, json: body, headers: headers, receive_timeout: 60_000, retry: false) do
      {:ok, %{status: 200, body: %{"result" => task}}} ->
        outputs = outputs(get_in(task, ["status", "message", "parts"]) || [])
        Enum.each(outputs, on_output)
        {:ok, %{state | context_id: task["contextId"] || state.context_id}, outputs}

      {:ok, %{body: %{"error" => error}}} ->
        {:error, error["message"]}

      {:ok, response} ->
        {:error, "HTTP #{response.status}"}

      {:error, error} ->
        {:error, Exception.message(error)}
    end
  end

  defp stream(state, body, headers, on_output) do
    collect = fn {:data, data}, {request, response} ->
      {events, rest} = SSE.split(Req.Response.get_private(response, :buffer, "") <> data)

      found =
        for %{"data" => json} <- events,
            %{"result" => result} <- [Jason.decode!(json)],
            do: result

      outputs =
        Enum.flat_map(
          found,
          &(&1 |> get_in(["status", "message", "parts"]) |> List.wrap() |> outputs())
        )

      Enum.each(outputs, on_output)
      context = Enum.find_value(found, & &1["contextId"])

      response =
        response
        |> Req.Response.put_private(:buffer, rest)
        |> Req.Response.update_private(:outputs, outputs, &(&1 ++ outputs))
        |> then(&if context, do: Req.Response.put_private(&1, :context_id, context), else: &1)

      {:cont, {request, response}}
    end

    case Req.post(state.url,
           json: body,
           headers: headers,
           into: collect,
           receive_timeout: 60_000,
           retry: false
         ) do
      {:ok, %{status: 200} = response} ->
        context = Req.Response.get_private(response, :context_id, state.context_id)
        {:ok, %{state | context_id: context}, Req.Response.get_private(response, :outputs, [])}

      {:ok, response} ->
        {:error, "HTTP #{response.status}"}

      {:error, error} ->
        {:error, Exception.message(error)}
    end
  end

  # Text parts, and the A2UI messages of data parts.
  defp outputs(parts) do
    Enum.flat_map(parts, fn
      %{"kind" => "text", "text" => text} ->
        [{:text, text}]

      part ->
        case A2A.a2ui_messages([part]) do
          [] -> []
          messages -> [{:a2ui, messages}]
        end
    end)
  end
end

defmodule Gallery.A2AClient do
  @moduledoc """
  A small client for A2A's JSON-RPC binding, as the chat page uses it:
  `message/stream` with text and A2UI parts and the renderer's metadata,
  the A2UI extension requested in the `X-A2A-Extensions` header.

  `stream/2` runs in a process of its own and reports to `:to`:

    * `{:a2a_parts, ref, parts, context_id}` for each streamed event
      (`context_id` may be `nil`),
    * `{:a2a_done, ref, :ok | {:error, reason}}` at the end.
  """

  alias A2UIAgent.A2A

  @doc "The agent card at `base_url`, or an error."
  def agent_card(base_url) do
    case Req.get(base_url <> "/.well-known/agent-card.json", retry: false, receive_timeout: 5_000) do
      {:ok, %{status: 200, body: %{} = card}} -> {:ok, card}
      {:ok, response} -> {:error, "HTTP #{response.status}"}
      {:error, error} -> {:error, Exception.message(error)}
    end
  end

  @doc """
  Sends a message and streams the answer. Options: `:url` (the JSON-RPC
  endpoint), `:parts`, `:metadata`, `:context_id`, `:to` (the pid to
  report to), `:ref`.
  """
  def stream(options) do
    to = Keyword.fetch!(options, :to)
    ref = Keyword.fetch!(options, :ref)

    message =
      %{
        "kind" => "message",
        "messageId" => "gallery-#{System.unique_integer([:positive])}",
        "role" => "user",
        "parts" => Keyword.fetch!(options, :parts),
        "metadata" => Keyword.get(options, :metadata, %{})
      }
      |> put_present("contextId", options[:context_id])

    body = %{
      "jsonrpc" => "2.0",
      "id" => System.unique_integer([:positive]),
      "method" => "message/stream",
      "params" => %{"message" => message}
    }

    headers = [{"x-a2a-extensions", A2A.extension_uri("1.0")}]

    collect = fn {:data, data}, {request, response} ->
      {events, rest} = split(Req.Response.get_private(response, :buffer, "") <> data)

      for %{"data" => json} <- events, %{"result" => result} <- [Jason.decode!(json)] do
        parts = result |> get_in(["status", "message", "parts"]) |> List.wrap()
        send(to, {:a2a_parts, ref, parts, result["contextId"]})
      end

      {:cont, {request, Req.Response.put_private(response, :buffer, rest)}}
    end

    outcome =
      case Req.post(Keyword.fetch!(options, :url),
             json: body,
             headers: headers,
             into: collect,
             receive_timeout: 60_000,
             retry: false
           ) do
        {:ok, %{status: 200}} -> :ok
        {:ok, response} -> {:error, "HTTP #{response.status}"}
        {:error, error} -> {:error, Exception.message(error)}
      end

    send(to, {:a2a_done, ref, outcome})
  end

  # Server-sent events: the complete events in the buffer, and the rest.
  defp split(buffer) do
    parts = String.split(String.replace(buffer, "\r\n", "\n"), "\n\n")
    {complete, [rest]} = Enum.split(parts, -1)
    {complete |> Enum.map(&event/1) |> Enum.reject(&(&1 == %{})), rest}
  end

  defp event(text) do
    text
    |> String.split("\n")
    |> Enum.reduce(%{}, fn line, event ->
      case String.split(line, ":", parts: 2) do
        [field, value] when field != "" ->
          value = String.trim_leading(value, " ")
          Map.update(event, field, value, &(&1 <> "\n" <> value))

        _comment_or_blank ->
          event
      end
    end)
  end

  defp put_present(map, _key, nil), do: map
  defp put_present(map, key, value), do: Map.put(map, key, value)
end

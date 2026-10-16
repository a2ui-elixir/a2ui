defmodule TerminalClient.Transports.SSE do
  @moduledoc """
  Plain server-sent events: one A2UI message per event, from
  `GET /events?q=...`. The stream only goes one way, so the renderer's
  messages stay home. Each event has an id: a client that loses the
  connection reconnects with `Last-Event-ID` and gets the rest.
  """

  @behaviour TerminalClient.Transport

  alias TerminalClient.SSE

  @impl true
  def connect(url, options),
    do: {:ok, %{url: url, version: Keyword.get(options, :version, "v1.0")}}

  @impl true
  def supports?(_message), do: false

  @impl true
  def request(state, inputs, _metadata, on_output) do
    query = for {:text, text} <- inputs, into: "", do: text
    params = [q: query] ++ if(state.version == "v1.0", do: [], else: [version: "v0.9"])

    collect = fn {:data, data}, {request, response} ->
      {events, rest} = SSE.split(Req.Response.get_private(response, :buffer, "") <> data)
      outputs = for %{"data" => json} <- events, do: {:a2ui, [Jason.decode!(json)]}
      Enum.each(outputs, on_output)

      response =
        response
        |> Req.Response.put_private(:buffer, rest)
        |> Req.Response.update_private(:outputs, outputs, &(&1 ++ outputs))

      {:cont, {request, response}}
    end

    case Req.get(state.url, params: params, into: collect, receive_timeout: 60_000, retry: false) do
      {:ok, %{status: 200} = response} ->
        {:ok, state, Req.Response.get_private(response, :outputs, [])}

      {:ok, response} ->
        {:error, "HTTP #{response.status}"}

      {:error, error} ->
        {:error, Exception.message(error)}
    end
  end
end

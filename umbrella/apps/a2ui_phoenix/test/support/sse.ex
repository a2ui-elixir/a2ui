defmodule A2UIPhoenix.Test.SSE do
  @moduledoc false
  # Reads an event stream the way a browser does (WHATWG HTML, "Parsing an
  # event stream"): `data` lines accumulate, a blank line dispatches the
  # event, comments and unknown fields are ignored, and an event without
  # data or without the blank line that ends it is dropped.

  def parse(body) do
    state =
      body
      |> String.split(~r/\r\n|\r|\n/)
      |> Enum.reduce(%{events: [], current: nil, last_id: nil}, &line/2)

    Enum.reverse(state.events)
  end

  # The data of each `message` event, decoded as JSON.
  def json(body) do
    for %{event: "message", data: data} <- parse(body), do: Jason.decode!(data)
  end

  # A blank line dispatches the event with the last event id seen so far,
  # which carries over to later events until an `id` line changes it.
  defp line("", %{current: nil} = state), do: state
  defp line("", %{current: %{data: []}} = state), do: %{state | current: nil}

  defp line("", %{current: current} = state) do
    event = %{
      event: current.event,
      data: Enum.join(Enum.reverse(current.data), "\n"),
      id: state.last_id
    }

    %{state | events: [event | state.events], current: nil}
  end

  defp line(":" <> _comment, state), do: state

  defp line(text, state) do
    {name, value} =
      case String.split(text, ":", parts: 2) do
        [name, " " <> value] -> {name, value}
        [name, value] -> {name, value}
        [name] -> {name, ""}
      end

    field(name, value, %{state | current: state.current || %{event: "message", data: []}})
  end

  defp field("data", value, %{current: current} = state),
    do: %{state | current: %{current | data: [value | current.data]}}

  defp field("event", value, %{current: current} = state),
    do: %{state | current: %{current | event: value}}

  defp field("id", value, state) do
    if String.contains?(value, <<0>>), do: state, else: %{state | last_id: value}
  end

  defp field(_name, _value, state), do: state
end

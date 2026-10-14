defmodule A2UIPhoenix.Test.SSE do
  @moduledoc false
  # Reads an event stream the way a browser does (WHATWG HTML, "Parsing an
  # event stream"): `data` lines accumulate, a blank line dispatches the
  # event, comments and unknown fields are ignored, and an event without
  # data or without the blank line that ends it is dropped.

  def parse(body) do
    {events, _current} =
      body
      |> String.split(~r/\r\n|\r|\n/)
      |> Enum.reduce({[], nil}, &line/2)

    Enum.reverse(events)
  end

  # The data of each `message` event, decoded as JSON.
  def json(body) do
    for %{event: "message", data: data} <- parse(body), do: Jason.decode!(data)
  end

  defp line("", {events, nil}), do: {events, nil}
  defp line("", {events, %{data: []}}), do: {events, nil}

  defp line("", {events, current}),
    do:
      {[%{event: current.event, data: Enum.join(Enum.reverse(current.data), "\n")} | events], nil}

  defp line(":" <> _comment, acc), do: acc

  defp line(text, {events, current}) do
    {name, value} =
      case String.split(text, ":", parts: 2) do
        [name, " " <> value] -> {name, value}
        [name, value] -> {name, value}
        [name] -> {name, ""}
      end

    {events, field(name, value, current || %{event: "message", data: []})}
  end

  defp field("data", value, current), do: %{current | data: [value | current.data]}
  defp field("event", value, current), do: %{current | event: value}
  defp field(_name, _value, current), do: current
end

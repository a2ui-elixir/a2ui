defmodule TerminalClient.SSE do
  @moduledoc "Reads server-sent events from a buffer of received bytes."

  @doc """
  The complete events in `buffer`, each as a map of its fields (`"data"`
  lines joined), and the incomplete rest.
  """
  @spec split(String.t()) :: {[map()], String.t()}
  def split(buffer) do
    parts = String.split(String.replace(buffer, "\r\n", "\n"), "\n\n")
    {complete, [rest]} = Enum.split(parts, -1)
    {complete |> Enum.map(&event/1) |> Enum.reject(&(&1 == %{})), rest}
  end

  defp event(text) do
    text
    |> String.split("\n")
    |> Enum.reduce(%{}, fn line, event ->
      case String.split(line, ":", parts: 2) do
        ["", _comment] ->
          event

        [field, value] ->
          Map.update(
            event,
            field,
            String.trim_leading(value, " "),
            &(&1 <> "\n" <> String.trim_leading(value, " "))
          )

        [_blank] ->
          event
      end
    end)
  end
end

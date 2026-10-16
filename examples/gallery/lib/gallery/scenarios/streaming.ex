defmodule Gallery.Scenarios.Streaming do
  @moduledoc """
  A model's answer read while it streams. The scripted model writes text
  and A2UI messages in the direct JSON format (`<a2ui-json>` blocks);
  the agent feeds each chunk to `A2UIAgent.DirectJson.Parser.parse_chunk/3`
  and sends on whatever messages the chunk completes. The surface is
  created as soon as its message closes, components appear one by one
  (children not sent yet render as placeholders), and a long text value
  grows as it arrives. The same answer in the Express format is applied
  only once complete: Express does not stream.
  """

  use Gallery.Scenario

  alias A2UIAgent.DirectJson
  alias A2UIAgent.DirectJson.Parser
  alias A2UIAgent.Express

  @chunk_size 32
  @chunk_ms 60

  def id, do: "streaming"
  def title, do: "Streaming"

  def summary,
    do:
      "A model's answer parsed chunk by chunk with the agent SDK: the surface builds itself while the text arrives."

  def features,
    do: [
      "DirectJson.Parser.parse_chunk",
      "progressive components",
      "progressive text values",
      "placeholders",
      "text and UI interleaved",
      "Express (whole answers)"
    ]

  def messages, do: []
  def start, do: stream(0, @chunk_ms)

  @doc "The model's answer as `start/0` streams it: `{at_ms, chunk}` for each chunk."
  def chunks_at do
    answer()
    |> chunks()
    |> Enum.with_index(1)
    |> Enum.map(fn {chunk, index} -> {index * @chunk_ms, chunk} end)
  end

  def script, do: answer() <> "\n\n--- The same answer in Express ---\n\n" <> express_answer()

  defp parser_catalogs, do: [Gallery.Catalogs.basic("v1.0")]

  @days [{"Mon", "☀️", 24}, {"Tue", "☀️", 25}, {"Wed", "⛅", 22}, {"Thu", "🌧️", 19}, {"Fri", "⛅", 21}]

  defp forecast_messages do
    days = Enum.map(@days, fn {day, _sky, _temperature} -> String.downcase(day) end)

    cards =
      Enum.flat_map(@days, fn {day, sky, temperature} ->
        id = String.downcase(day)

        [
          %{"id" => id, "component" => "Card", "child" => id <> "Day", "weight" => 1},
          %{
            "id" => id <> "Day",
            "component" => "Column",
            "align" => "center",
            "children" => [id <> "Name", id <> "Sky", id <> "Degrees"]
          },
          text(id <> "Name", "##### #{day}"),
          text(id <> "Sky", "## #{sky}"),
          text(id <> "Degrees", "### #{temperature}°")
        ]
      end)

    [
      create("forecast"),
      components(
        "forecast",
        [
          %{
            "id" => "root",
            "component" => "Column",
            "children" => ["title", "summary", "days", "source"]
          },
          text("title", "## Lisbon, this week"),
          text("summary", path("/summary/text")),
          %{"id" => "days", "component" => "Row", "children" => days}
        ] ++
          cards ++
          [text("source", "Forecast by the gallery's scripted model.", %{"variant" => "caption"})]
      ),
      data("forecast", "/summary", %{
        "text" =>
          "A dry and sunny start to the week, with light winds from the north west. " <>
            "Clouds build on Wednesday and bring rain on Thursday, clearing by Friday afternoon."
      })
    ]
  end

  # The model's answer in the direct JSON format.
  defp answer do
    DirectJson.Parser.wrap([
      {:text, "Here is the week ahead in Lisbon. I'll fill in the details as they come."},
      {:a2ui_raw, Parser.decompile(forecast_messages())},
      {:text, "Anything else you'd like to know?"}
    ])
  end

  defp express_answer do
    {:ok, parser} = Express.Parser.new(parser_catalogs())
    {:ok, block} = Express.Parser.decompile(parser, forecast_messages())

    Express.Parser.wrap([
      {:text, "Here is the week ahead in Lisbon."},
      {:a2ui_raw, block},
      {:text, "Anything else you'd like to know?"}
    ])
  end

  # Each chunk's parts, at the time the chunk arrives. Text continues the
  # agent's last bubble until UI comes in between.
  defp stream(offset, chunk_ms) do
    {:ok, parser} = Parser.new(parser_catalogs(), progressive_keys: DirectJson.progressive_keys())

    {_parser, _in_text?, replies} =
      answer()
      |> chunks()
      |> Enum.with_index(1)
      |> Enum.reduce({parser, false, []}, fn {chunk, index}, {parser, in_text?, replies} ->
        {:ok, parser, parts} = Parser.parse_chunk(parser, chunk)

        {new, in_text?} =
          Enum.map_reduce(parts, in_text?, &to_reply(&1, &2, offset + index * chunk_ms))

        {parser, in_text?, replies ++ new}
      end)

    replies
  end

  defp to_reply({:text, text}, true, delay), do: {{delay, {:text_delta, text}}, true}
  defp to_reply({:text, text}, false, delay), do: {{delay, {:text, text}}, true}
  defp to_reply({:a2ui, messages}, _in_text?, delay), do: {{delay, messages}, false}

  defp chunks(text),
    do: text |> String.graphemes() |> Enum.chunk_every(@chunk_size) |> Enum.map(&Enum.join/1)

  # Express is parsed once the whole answer is in.
  defp express(offset) do
    {:ok, parser} = Express.Parser.new(parser_catalogs())
    answer = express_answer()
    {:ok, parts} = Express.Parser.parse_response(parser, answer)
    arrival = offset + length(chunks(answer)) * @chunk_ms

    [{offset, {:text, "(An Express answer is read when it is complete.)"}}] ++
      Enum.map(parts, fn
        {:text, text} -> {arrival, {:text, text}}
        {:a2ui, messages} -> {arrival, messages}
      end)
  end

  def controls,
    do: [
      {"again", "Stream it again"},
      {"slow", "Stream it slowly"},
      {"express", "The same answer in Express"}
    ]

  def control("again"), do: [{0, delete("forecast")} | stream(200, @chunk_ms)]
  def control("slow"), do: [{0, delete("forecast")} | stream(200, @chunk_ms * 4)]
  def control("express"), do: [{0, delete("forecast")} | express(200)]
  def control(_id), do: []
end

defmodule Gallery.Replays.Streaming do
  @moduledoc """
  The gallery's streaming scenario: the scripted model's answer arrives
  in chunks, `A2UIAgent.DirectJson.Parser.parse_chunk/3` reads each one,
  and every message it completes goes to the renderer at once.
  """

  alias A2UIPhoenix.Session
  alias Gallery.Replays.Recorder
  alias Gallery.Scenarios.Streaming, as: Scenario

  @doc "The replay."
  def replay do
    %{
      "id" => "streaming",
      "title" => "Streaming",
      "source" => "examples/gallery",
      "summary" =>
        "A model's answer parsed chunk by chunk: the surface builds while the text arrives.",
      "autoplay" => true,
      "steps" => Recorder.steps(record())
    }
  end

  defp record do
    session = Session.new(Scenario.catalogs(), Recorder.session_options(Scenario))
    chunks = Scenario.chunks_at()
    replies = Scenario.start()
    times = Enum.uniq(Enum.sort(Enum.map(chunks ++ replies, &elem(&1, 0))))

    {steps, {_session, _seen}} =
      Enum.map_reduce(times, {session, MapSet.new()}, fn at, {session, seen} ->
        chunk = Enum.join(for({^at, text} <- chunks, do: text))
        payloads = for {^at, payload} <- replies, do: payload
        {session, step} = Enum.reduce(payloads, {session, %{entries: []}}, &take/2)

        kinds = MapSet.new(Enum.map(step.entries, & &1["kind"]))
        {caption, seen} = caption(step, kinds, seen)

        step =
          Map.merge(step, %{
            at: at,
            chunk: chunk,
            caption: caption,
            surfaces: Recorder.surfaces(session)
          })

        {step, {session, seen}}
      end)

    steps
  end

  defp take({:text, text}, {session, step}), do: {session, Map.put(step, :said, text)}

  defp take({:text_delta, text}, {session, step}),
    do: {session, Map.update(step, :said_more, text, &(&1 <> text))}

  defp take(messages, {session, step}) do
    messages = List.wrap(messages)
    {session, out} = Recorder.apply(session, messages)

    entries =
      Enum.map(messages, &Recorder.entry(:in, &1)) ++ Enum.map(out, &Recorder.entry(:out, &1))

    {session, Map.update!(step, :entries, &(&1 ++ entries))}
  end

  # A caption the first time something happens.
  defp caption(step, kinds, seen) do
    events = [
      {:text, step[:said] != nil,
       "The model's answer starts with plain text, and the agent passes each piece on as it arrives."},
      {:create, "createSurface" in kinds,
       "The first message is complete: the surface exists, before any of its components."},
      {:components, "updateComponents" in kinds,
       "Components arrive as the model writes them. Children not sent yet show as placeholders."},
      {:data, "updateDataModel" in kinds,
       "The data arrives, and the long text value grows with each chunk."},
      {:after, step[:said] != nil and MapSet.member?(seen, :create),
       "After the block, the model ends with more text."}
    ]

    Enum.find_value(events, {nil, seen}, fn {event, happened?, caption} ->
      if happened? and not MapSet.member?(seen, event),
        do: {caption, MapSet.put(seen, event)}
    end)
  end
end

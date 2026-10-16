defmodule Site.Replays do
  @moduledoc """
  Recorded runs of the examples, from `priv/replays.json`. The gallery
  writes that file (`mix gallery.replays` in `examples/gallery`) by running
  the real agents against an `A2UIPhoenix.Session`; each step holds the
  HTML the renderer drew for the surfaces it changed, the messages that
  crossed, what the agent said and what the user does next.

  The page draws the first step of the first replay with `view/2`, and
  `site.js` plays the rest from `json/0`, building each step the same way.
  """

  @path Path.expand("../../priv/replays.json", __DIR__)
  @external_resource @path
  @document @path |> File.read!() |> Jason.decode!(objects: :ordered_objects)

  @typedoc "An item of the conversation."
  @type chat_item ::
          %{type: :user | :agent, text: String.t()}
          | %{type: :action, label: String.t(), name: String.t()}
          | %{type: :surface | :deleted, id: String.t()}

  # Replays, steps and moves as maps; each message keeps its key order.
  normalize = fn
    normalize, %Jason.OrderedObject{values: values} ->
      Map.new(values, fn
        {"message", message} -> {"message", message}
        {key, value} -> {key, normalize.(normalize, value)}
      end)

    normalize, list when is_list(list) ->
      Enum.map(list, &normalize.(normalize, &1))

    _normalize, other ->
      other
  end

  @replays normalize.(normalize, @document["replays"])

  @doc "The replays, in the order the page shows them."
  def all, do: @replays

  @doc """
  The replays as JSON for a `<script type="application/json">` element.
  Every `<` is escaped, so nothing in the recorded HTML can end the
  element early.
  """
  def json, do: @document |> Jason.encode!() |> String.replace("<", "\\u" <> "003c")

  @doc """
  What the player shows at step `index` of `replay`: the conversation
  (`chat`), the HTML of the surfaces it holds, the messages so far (each
  `{entry, step}`), the model's output so far for a streamed replay, the
  caption (the latest one) and the step's next move.
  """
  def view(replay, index) do
    steps = Enum.take(replay["steps"], index + 1)
    initial = %{chat: [], surfaces: %{}, entries: [], stream: "", chunk: "", caption: nil}

    view =
      steps
      |> Enum.with_index()
      |> Enum.reduce(initial, fn {step, at}, view ->
        previous = if at > 0, do: Enum.at(steps, at - 1)
        apply_step(view, step, previous, at)
      end)

    step = List.last(steps)

    Map.merge(view, %{
      step: step,
      index: index,
      count: length(replay["steps"]),
      next: step["next"]
    })
  end

  defp apply_step(view, step, previous, at) do
    entries = Enum.to_list(step["entries"] || [])

    view
    |> add_user(step, previous, entries)
    |> add_said(step)
    |> add_surfaces(step)
    |> Map.update!(:entries, &(&1 ++ Enum.map(entries, fn entry -> {entry, at} end)))
    |> Map.update!(:stream, &(&1 <> (step["chunk"] || "")))
    |> Map.put(:chunk, step["chunk"] || "")
    |> Map.update!(:caption, &(step["caption"] || &1))
  end

  # What the user says, or the action their click sent.
  defp add_user(view, %{"user" => text}, _previous, _entries) when is_binary(text),
    do: push(view, %{type: :user, text: text})

  defp add_user(view, _step, %{"next" => %{"do" => "click", "label" => label}}, entries) do
    case Enum.find(entries, &(&1["dir"] == "out" and &1["kind"] == "action")) do
      nil ->
        view

      entry ->
        push(view, %{type: :action, label: label, name: entry["message"]["action"]["name"]})
    end
  end

  defp add_user(view, _step, _previous, _entries), do: view

  # New text starts a bubble; more of it continues the last one.
  defp add_said(view, step) do
    view = if step["said"], do: push(view, %{type: :agent, text: step["said"]}), else: view

    case step["said_more"] do
      nil -> view
      more -> Map.update!(view, :chat, &continue(&1, more))
    end
  end

  defp continue(chat, more) do
    index = length(chat) - 1 - Enum.find_index(Enum.reverse(chat), &(&1.type == :agent))
    List.update_at(chat, index, &%{&1 | text: &1.text <> more})
  end

  # A surface joins the conversation when it first shows, in the order of
  # the step's `order`; one the agent deleted leaves a note.
  defp add_surfaces(view, step) do
    order = Enum.to_list(step["order"] || [])
    changed = Map.new(step["surfaces"] || [])
    surfaces = Map.merge(view.surfaces, changed)
    shown = for %{type: :surface, id: id} <- view.chat, do: id

    chat =
      Enum.map(view.chat, fn
        %{type: :surface, id: id} = item ->
          if id in order, do: item, else: %{type: :deleted, id: id}

        item ->
          item
      end)

    new =
      for id <- order, Map.has_key?(changed, id), id not in shown, do: %{type: :surface, id: id}

    %{view | chat: chat ++ new, surfaces: Map.take(surfaces, order)}
  end

  defp push(view, item), do: Map.update!(view, :chat, &(&1 ++ [item]))
end

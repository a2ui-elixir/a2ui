defmodule Gallery.Replays.Recorder do
  @moduledoc """
  What every replay records: the surfaces of a renderer session as
  `A2UIPhoenix` draws them, and the messages that cross between agent and
  renderer, step by step.

  A step is a map: `caption`, `user` (what the user says), `said` (what
  the agent says), `entries` (the messages, `"in"` from the agent and
  `"out"` from the renderer, each with the message in its canonical key
  order), `surfaces` (the HTML of each surface after the step) and `next`
  (what the user does to get to the next step).
  `steps/1` keeps only the surfaces each step changes.
  """

  import Phoenix.LiveViewTest, only: [render_component: 2]

  alias A2UICore.Resolution.{Binding, NodeResolver}
  alias A2UIPhoenix.{Context, Session}
  alias GalleryWeb.{Markdown, RestaurantComponents}

  @endpoint GalleryWeb.Endpoint

  @clock ~U[2026-10-16 12:00:00Z]

  @doc "The time every replay happens at."
  def now, do: @clock

  @doc "A scenario's session options, with the replays' clock."
  def session_options(scenario),
    do: Keyword.put(scenario.session_options(), :clock, fn -> @clock end)

  @doc """
  Steps from the first one and the moves after it: each move is
  `{next, step}`, where `next` (what the user does) goes on the step
  before.
  """
  def chain(first, moves) do
    {steps, last} =
      Enum.map_reduce(moves, first, fn {next, step}, previous ->
        {Map.put(previous, :next, next), step}
      end)

    steps ++ [last]
  end

  @doc """
  A click on the element `selector` finds, labelled `label`; `text` says
  what the user does (`Click <label>` by default).
  """
  def click_move(selector, label, text \\ nil),
    do: %{
      "do" => "click",
      "target" => selector,
      "label" => label,
      "text" => text || "Click " <> label
    }

  @doc "Entering `value` into the input `selector` finds; `text` says what the user does."
  def type_move(selector, value, text),
    do: %{"do" => "type", "target" => selector, "value" => to_string(value), "text" => text}

  @doc "The agent acts without the user; `text` says what happens."
  def wait_move(text), do: %{"do" => "wait", "text" => text}

  @doc """
  The HTML of every surface of `session`, in order: `[{id, html}]`, as
  `A2UIPhoenix.Surface` renders it on the gallery's pages.
  """
  def surfaces(session, components \\ %{}) do
    components = Map.merge(RestaurantComponents.components(), components)

    for surface <- Session.surfaces(session) do
      html =
        render_component(A2UIPhoenix.Surface,
          id: "surface-" <> surface.id,
          session: session,
          surface_id: surface.id,
          components: components,
          markdown: &Markdown.to_html/1
        )

      {surface.id, compact(html)}
    end
  end

  # Runs of whitespace render as one space, except in a textarea.
  defp compact(html) do
    ~r{<textarea\b[^>]*>.*?</textarea>}s
    |> Regex.split(html, include_captures: true)
    |> Enum.map_join(fn
      "<textarea" <> _rest = textarea -> textarea
      other -> String.replace(other, ~r/\s+/, " ")
    end)
  end

  @doc """
  A log entry for `message`: `:in` when the agent sends it, `:out` when
  the renderer does. `note` replaces the summary of what it holds.
  """
  def entry(direction, message, note \\ nil) when direction in [:in, :out] do
    %{
      "dir" => Atom.to_string(direction),
      "kind" => kind(message),
      "note" => note || summary(message),
      "message" => A2UICore.KeyOrder.message(message)
    }
  end

  @doc "The kind of a message: its key besides `version`."
  def kind(message), do: message |> Map.delete("version") |> Map.keys() |> List.first()

  defp summary(%{"createSurface" => %{"surfaceId" => id} = body}) do
    case body["components"] do
      [_ | _] = components -> "#{id} · #{length(components)} components"
      _none -> id
    end
  end

  defp summary(%{"updateComponents" => %{"surfaceId" => id, "components" => components}}),
    do: "#{id} · #{length(components)} components"

  defp summary(%{"updateDataModel" => %{"surfaceId" => id} = body}),
    do: "#{id} · #{body["path"] || "/"}"

  defp summary(%{"deleteSurface" => %{"surfaceId" => id}}), do: id
  defp summary(%{"action" => %{"name" => name}}), do: name
  defp summary(%{"callAgentFunction" => %{"callFunction" => %{"@call" => name}}}), do: name
  defp summary(%{"callRendererFunction" => %{"callFunction" => %{"@call" => name}}}), do: name
  defp summary(%{"agentFunctionResponse" => %{"functionCallId" => id}}), do: id
  defp summary(%{"rendererFunctionResponse" => %{"functionCallId" => id}}), do: id
  defp summary(%{"error" => %{"code" => code}}), do: code
  defp summary(_message), do: nil

  @doc "The mounted nodes of a surface, in document order."
  def nodes(session, surface_id) do
    session
    |> Session.resolver(surface_id)
    |> NodeResolver.positions()
    |> Enum.sort_by(fn {position, _node} -> position end)
    |> Enum.map(fn {_position, node} -> node end)
  end

  @doc "The value of a prop: a binding's current value, or the prop itself."
  def value(%Binding{value: value}), do: value
  def value(other), do: other

  @doc "The Button whose label is `label`, the `nth` one when several are."
  def button(session, surface_id, label, nth \\ 0) do
    resolver = Session.resolver(session, surface_id)

    buttons =
      for node <- nodes(session, surface_id),
          node.type == "Button",
          {:node, child} = node.props["child"],
          value(NodeResolver.node(resolver, child).props["text"]) == label,
          do: node

    Enum.at(buttons, nth) || raise "no button #{inspect(label)} on #{surface_id}"
  end

  @doc "The input component whose label is `label`."
  def field(session, surface_id, label) do
    Enum.find(nodes(session, surface_id), &(value(&1.props["label"]) == label)) ||
      raise "no field #{inspect(label)} on #{surface_id}"
  end

  @doc "The DOM id the surface gives `node` (or an element inside it, with `suffix`)."
  def dom_id(surface_id, node, suffix \\ nil),
    do: Context.dom_id(%Context{surface_id: surface_id}, node, suffix)

  @doc "Clicks `node`'s action; returns the session and what the renderer sends."
  def click(session, surface_id, node) do
    {:ok, session, effects} = Session.invoke(session, surface_id, node.ref, "action")
    {session, outbound(effects)}
  end

  @doc "Writes `value` to `node`'s two-way binding; returns the session and what the renderer sends."
  def write(session, surface_id, node, value, property \\ "value") do
    {:ok, session, effects} = Session.write(session, surface_id, node.ref, property, value)
    {session, outbound(effects)}
  end

  @doc "Applies agent messages; returns the session and what the renderer sends back."
  def apply(session, messages) do
    {:ok, session, effects} = Session.handle_message(session, messages)
    {session, outbound(effects)}
  end

  defp outbound(effects), do: for({:send, message} <- effects, do: message)

  @doc """
  Steps with only the surfaces each one changes (`surfaces`, by id) and
  the ids of the surfaces showing after it (`order`).
  """
  def steps(steps) do
    {steps, _shown} =
      Enum.map_reduce(steps, %{}, fn step, shown ->
        current = Map.new(step.surfaces)

        changed =
          for {id, html} <- step.surfaces, Map.get(shown, id) != html, into: %{}, do: {id, html}

        step =
          step
          |> Map.drop([:surfaces])
          |> Map.merge(%{surfaces: changed, order: Enum.map(step.surfaces, &elem(&1, 0))})
          |> Map.new(fn {key, value} -> {Atom.to_string(key), value} end)
          |> Map.reject(fn {key, value} -> key != "order" and value in [nil, [], ""] end)

        {step, current}
      end)

    steps
  end
end

defmodule TerminalClient.Text do
  @moduledoc """
  Draws a resolved surface as lines of text: the terminal's rendition of
  the basic catalog, and of the restaurant catalog's `Rating`.

      ┌──────────────────────────────┐
      │ Trattoria Roma               │
      │ ★★★★★ 4.6 · 412 reviews      │
      │ [ Book a table ]             │
      └──────────────────────────────┘

  A node waiting for an agent function shows `…`; a component the
  renderer cannot draw shows its type in angle brackets.
  """

  alias A2UICore.Resolution.{Node, NodeResolver}
  alias TerminalClient.Renderer

  @doc "The lines of surface `surface_id`, or `[]` while it has no root."
  @spec render(Renderer.t(), String.t()) :: [String.t()]
  def render(renderer, surface_id) do
    resolver = Renderer.resolver(renderer, surface_id)

    case resolver && NodeResolver.root(resolver) do
      nil -> []
      root -> attribution(Renderer.surface(renderer, surface_id)) ++ node(root, resolver)
    end
  end

  # A v0.9 theme names the agent that made the surface.
  defp attribution(%{theme: %{"agentDisplayName" => name}}) when is_binary(name),
    do: ["— #{name} —"]

  defp attribution(_surface), do: []

  defp node(%Node{state: :resolved, busy: true} = node, resolver) do
    case draw(node, resolver) do
      ["" | rest] -> ["…" | rest]
      [first | rest] -> [first <> " …" | rest]
      [] -> ["…"]
    end
  end

  defp node(%Node{state: :resolved} = node, resolver), do: draw(node, resolver)
  defp node(%Node{state: :pending}, _resolver), do: ["…"]
  defp node(%Node{} = node, _resolver), do: ["<#{node.type || node.component_id}>"]

  defp child(resolver, {:node, ref}), do: node(NodeResolver.node(resolver, ref), resolver)

  defp child(resolver, children) when is_list(children),
    do: Enum.flat_map(children, &child(resolver, &1))

  defp child(_resolver, _none), do: []

  defp draw(%Node{type: "Text", props: props}, _resolver) do
    text = to_text(props["text"]) || ""

    case props["variant"] do
      "caption" -> [text]
      variant when variant in ~w(h1 h2 h3 h4 h5) -> [String.upcase(text)]
      _body -> markdown(text)
    end
  end

  defp draw(%Node{type: type, props: props}, resolver) when type in ["Column", "Card", "List"] do
    lines = child(resolver, props["children"] || props["child"])

    cond do
      type == "Card" -> box(lines)
      type == "List" and props["direction"] == "horizontal" -> [Enum.join(lines, "  ")]
      true -> lines
    end
  end

  defp draw(%Node{type: "Row", props: props}, resolver) do
    parts = Enum.map(List.wrap(props["children"]), &child(resolver, &1))

    if Enum.all?(parts, &(length(&1) <= 1)),
      do: [parts |> List.flatten() |> Enum.join("  ")],
      else: List.flatten(parts)
  end

  defp draw(%Node{type: "Button", props: props}, resolver) do
    label = props["child"] |> then(&child(resolver, &1)) |> Enum.join(" ")
    disabled = if props["isValid"] == false, do: " (disabled)", else: ""

    if props["variant"] == "primary",
      do: ["[* #{label} *]#{disabled}"],
      else: ["[ #{label} ]#{disabled}"]
  end

  defp draw(%Node{type: "TextField", props: props} = node, _resolver),
    do: ["#{to_text(props["label"])}: [#{to_text(props["value"])}]" | errors(node)]

  defp draw(%Node{type: "CheckBox", props: props}, _resolver),
    do: [
      "[#{if Renderer.text(props["value"]) == true, do: "x", else: " "}] #{to_text(props["label"])}"
    ]

  defp draw(%Node{type: "ChoicePicker", props: props}, _resolver) do
    chosen = List.wrap(Renderer.text(props["value"]))
    single? = props["variant"] == "mutuallyExclusive"

    options =
      Enum.map_join(props["options"] || [], "  ", fn option ->
        mark =
          if option["value"] in chosen,
            do: if(single?, do: "(•)", else: "[x]"),
            else: if(single?, do: "( )", else: "[ ]")

        "#{mark} #{to_text(option["label"])}"
      end)

    ["#{to_text(props["label"])}: #{options}"]
  end

  defp draw(%Node{type: "Slider", props: props}, _resolver),
    do: [
      "#{to_text(props["label"])}: #{to_text(props["value"])} (#{props["min"] || 0}–#{props["max"]})"
    ]

  defp draw(%Node{type: "DateTimeInput", props: props}, _resolver),
    do: ["#{to_text(props["label"]) || "Date"}: #{to_text(props["value"])}"]

  defp draw(%Node{type: "Image", props: props}, _resolver),
    do: ["[image #{to_text(props["description"]) || Path.basename(to_text(props["url"]) || "")}]"]

  defp draw(%Node{type: "Icon", props: props}, _resolver), do: ["(#{icon_name(props["name"])})"]

  defp draw(%Node{type: "Video", props: props}, _resolver),
    do: ["[video #{to_text(props["url"])}]"]

  defp draw(%Node{type: "AudioPlayer", props: props}, _resolver),
    do: ["[audio #{to_text(props["url"])}]"]

  defp draw(%Node{type: "Divider"}, _resolver), do: [String.duplicate("─", 24)]

  defp draw(%Node{type: "Tabs", props: props}, resolver) do
    tabs = props["tabs"] || []
    titles = Enum.map_join(tabs, " | ", &to_text(&1["title"]))
    first = tabs |> List.first(%{}) |> Map.get("child")
    ["Tabs: #{titles}" | child(resolver, first)]
  end

  defp draw(%Node{type: "Modal", props: props}, resolver),
    do: child(resolver, props["trigger"]) ++ ["  (opens a dialog)"]

  defp draw(%Node{type: "Rating", props: props}, _resolver) do
    max = props["max"] || 5
    value = Renderer.text(props["value"])
    full = if is_number(value), do: value |> round() |> min(max) |> max(0), else: 0
    label = if props["label"], do: " #{to_text(props["label"])}", else: ""
    [String.duplicate("★", full) <> String.duplicate("☆", max - full) <> label]
  end

  defp draw(%Node{type: type}, _resolver), do: ["<#{type}>"]

  defp errors(%Node{props: props}) do
    for message <- props["validationErrors"] || [], do: "  ! #{message}"
  end

  # Markdown headings and emphasis, as plain text.
  defp markdown(text) do
    text
    |> String.split("\n")
    |> Enum.map(fn line ->
      line = String.replace(line, ~r/\*\*|__|`/, "")

      case Regex.run(~r/\A#+\s+(.*)\z/, line) do
        [_, heading] -> String.upcase(heading)
        nil -> line
      end
    end)
  end

  defp icon_name(%{"@path" => _path}), do: "icon"
  defp icon_name(name), do: to_text(name)

  defp box(lines) do
    width = lines |> Enum.map(&String.length/1) |> Enum.max(fn -> 0 end)
    bar = String.duplicate("─", width + 2)
    ["┌#{bar}┐"] ++ Enum.map(lines, &"│ #{String.pad_trailing(&1, width)} │") ++ ["└#{bar}┘"]
  end

  defp to_text(value) do
    case Renderer.text(value) do
      nil ->
        nil

      text when is_binary(text) ->
        text

      number when is_float(number) ->
        if number == trunc(number),
          do: Integer.to_string(trunc(number)),
          else: Float.to_string(number)

      other ->
        to_string(other)
    end
  end
end

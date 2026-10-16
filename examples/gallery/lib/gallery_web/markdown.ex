defmodule GalleryWeb.Markdown do
  @moduledoc """
  The simple Markdown a v1.0 `Text` may hold: headings, bold, italic,
  inline code and bullet lists. HTML in the text is escaped, and links
  and images are left as text, as the basic catalog asks.
  """

  import Phoenix.HTML, only: [html_escape: 1, raw: 1, safe_to_string: 1]

  @doc "Renders `text` as safe HTML."
  @spec to_html(String.t() | nil) :: Phoenix.HTML.safe()
  def to_html(nil), do: raw("")

  def to_html(text) do
    text
    |> String.split(~r/\r?\n/)
    |> Enum.chunk_by(&String.starts_with?(&1, ["- ", "* "]))
    |> Enum.map_join(&block/1)
    |> raw()
  end

  defp block([first | _] = lines) do
    if String.starts_with?(first, ["- ", "* "]) do
      items =
        Enum.map_join(lines, fn line ->
          "<li>" <> inline(String.slice(line, 2..-1//1)) <> "</li>"
        end)

      "<ul>" <> items <> "</ul>"
    else
      Enum.map_join(lines, &line/1)
    end
  end

  defp line(""), do: ""

  defp line(line) do
    case Regex.run(~r/\A(#{"#"}{1,5})\s+(.*)\z/, line) do
      [_, hashes, heading] ->
        level = String.length(hashes)
        "<h#{level}>#{inline(heading)}</h#{level}>"

      nil ->
        "<p>" <> inline(line) <> "</p>"
    end
  end

  defp inline(text) do
    text
    |> html_escape()
    |> safe_to_string()
    |> String.replace(~r/`([^`]+)`/, "<code>\\1</code>")
    |> String.replace(~r/\*\*([^*]+)\*\*/, "<strong>\\1</strong>")
    |> String.replace(~r/(?<![\w*])\*([^*]+)\*(?![\w*])/, "<em>\\1</em>")
    |> String.replace(~r/(?<!\w)_([^_]+)_(?!\w)/, "<em>\\1</em>")
  end
end

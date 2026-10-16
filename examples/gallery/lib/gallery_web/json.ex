defmodule GalleryWeb.JSON do
  @moduledoc """
  Highlighting for the JSON the gallery shows: object keys, strings,
  numbers and literals become `<span>`s with the `j-key`, `j-str`,
  `j-num` and `j-lit` classes; everything else is escaped as it is.

      iex> GalleryWeb.JSON.highlight(~s({"a": [1, true]})) |> Phoenix.HTML.safe_to_string()
      ~s({<span class="j-key">&quot;a&quot;</span>: [<span class="j-num">1</span>, <span class="j-lit">true</span>]})
  """

  @token ~r/"(?:\\.|[^"\\])*"(?:\s*:)?|\b(?:true|false|null)\b|-?\b\d+(?:\.\d+)?(?:[eE][+-]?\d+)?\b/
  @key ~r/\A("(?:\\.|[^"\\])*")(\s*:)\z/

  @doc "The highlighted HTML of `code`."
  def highlight(code) when is_binary(code) do
    {:safe, @token |> Regex.split(code, include_captures: true) |> Enum.map(&token/1)}
  end

  defp token(""), do: []

  defp token(<<?", _rest::binary>> = token) do
    case Regex.run(@key, token) do
      [_, key, colon] -> [span("j-key", key), escape(colon)]
      nil -> span("j-str", token)
    end
  end

  defp token(literal) when literal in ["true", "false", "null"], do: span("j-lit", literal)

  defp token(text) do
    if Regex.match?(~r/\A-?\d/, text), do: span("j-num", text), else: escape(text)
  end

  defp span(class, text), do: [~s(<span class="), class, ~s(">), escape(text), "</span>"]

  defp escape(text), do: text |> Phoenix.HTML.html_escape() |> Phoenix.HTML.safe_to_string()
end

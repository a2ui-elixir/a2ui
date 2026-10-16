defmodule A2UIAgent.BlockLexer do
  @moduledoc """
  Splits model output into conversational text and the raw blocks
  between a format's tags.

      iex> A2UIAgent.BlockLexer.tokenize("Hi <a2ui>root = Text(\\"</a2ui>\\")</a2ui> bye")
      [{:text, "Hi"}, {:a2ui_raw, ~s|root = Text("</a2ui>")|, true}, {:text, "bye"}]

  Inside a block, a closing tag counts only outside string literals and
  single-line comments: the scanner follows strings (with backslash
  escapes and triple-quoted forms) and comments until their end. The
  opening tag may carry attributes, and both tags ignore case. A block
  whose closing tag never comes is returned with `final?` false.

  Text and blocks are trimmed, and a Markdown code fence around either
  is dropped; text that is empty after that is left out.
  """

  @moduledoc since: "0.1.0"

  @typedoc "A part of an unwrapped response: text or an uncompiled block."
  @type raw_part :: {:text, String.t()} | {:a2ui_raw, String.t(), boolean()}

  @defaults [
    tag: "a2ui",
    string_delimiters: [~s("), "'"],
    comments: ["#"]
  ]

  @doc """
  Tokenizes `content`. Options: `:tag` (the tag name, default `"a2ui"`),
  `:string_delimiters` (default `"` and `'`) and `:comments` (the markers
  that start a single-line comment, default `#`).
  """
  @spec tokenize(String.t(), keyword()) :: [raw_part()]
  def tokenize(content, options \\ []) do
    options = Keyword.merge(@defaults, options)
    tag = Regex.escape(options[:tag])

    config = %{
      open: Regex.compile!("<#{tag}(?:\\s[^>]*)?>", "i"),
      close: Regex.compile!("\\A</#{tag}\\s*>", "i"),
      delimiters: options[:string_delimiters],
      comments: options[:comments]
    }

    normal(content, 0, config, [])
  end

  # Outside a block: the text up to the next opening tag.
  defp normal(content, from, config, parts) do
    case Regex.run(config.open, content, return: :index, offset: from) do
      nil ->
        Enum.reverse(add_text(parts, slice(content, from, byte_size(content))))

      [{start, length}] ->
        text = slice(content, from, start)
        block(content, start + length, start + length, config, {text, parts})
    end
  end

  # Inside a block, scanning from `i`; the block started at `from`.
  defp block(content, from, i, _config, acc) when i >= byte_size(content),
    do: finish(content, from, acc, false)

  defp block(content, from, i, config, {text, parts} = acc) do
    rest = slice(content, i, byte_size(content))

    cond do
      match = :binary.at(content, i) == ?< && Regex.run(config.close, rest, return: :index) ->
        [{0, length}] = match
        raw = clean(slice(content, from, i))
        parts = [{:a2ui_raw, raw, true} | add_text(parts, text)]
        normal(content, i + length, config, parts)

      delimiter = Enum.find(config.delimiters, &String.starts_with?(rest, &1)) ->
        triple = String.duplicate(delimiter, 3)
        quote = if String.starts_with?(rest, triple), do: triple, else: delimiter
        in_string(content, from, i + byte_size(quote), quote, config, acc)

      marker = Enum.find(config.comments, &String.starts_with?(rest, &1)) ->
        in_comment(content, from, i + byte_size(marker), config, acc)

      true ->
        block(content, from, i + 1, config, acc)
    end
  end

  defp in_string(content, from, i, _quote, _config, acc) when i >= byte_size(content),
    do: finish(content, from, acc, false)

  defp in_string(content, from, i, quote, config, acc) do
    cond do
      :binary.at(content, i) == ?\\ ->
        in_string(content, from, i + 2, quote, config, acc)

      String.starts_with?(slice(content, i, byte_size(content)), quote) ->
        block(content, from, i + byte_size(quote), config, acc)

      true ->
        in_string(content, from, i + 1, quote, config, acc)
    end
  end

  defp in_comment(content, from, i, _config, acc) when i >= byte_size(content),
    do: finish(content, from, acc, false)

  defp in_comment(content, from, i, config, acc) do
    if :binary.at(content, i) in [?\n, ?\r],
      do: block(content, from, i + 1, config, acc),
      else: in_comment(content, from, i + 1, config, acc)
  end

  defp finish(content, from, {text, parts}, final?) do
    raw = clean(slice(content, from, byte_size(content)))
    Enum.reverse([{:a2ui_raw, raw, final?} | add_text(parts, text)])
  end

  defp add_text(parts, text) do
    case clean(text) do
      "" -> parts
      cleaned -> [{:text, cleaned} | parts]
    end
  end

  @doc """
  Trims `text` and drops a Markdown code fence around it.

      iex> A2UIAgent.BlockLexer.clean("```express\\nroot = Text(\\"x\\")\\n```")
      ~s|root = Text("x")|
  """
  @spec clean(String.t()) :: String.t()
  def clean(text) do
    text
    |> String.trim()
    |> String.replace(~r/\A```[a-zA-Z-]*\s*/i, "")
    |> String.replace(~r/\s*```[a-zA-Z-]*\z/i, "")
    |> String.trim()
  end

  defp slice(content, from, to) when to > from, do: binary_part(content, from, to - from)
  defp slice(_content, _from, _to), do: ""
end

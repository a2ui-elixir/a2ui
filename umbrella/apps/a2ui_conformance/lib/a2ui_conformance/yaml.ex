defmodule A2UIConformance.Yaml do
  @moduledoc false

  # Loads conformance YAML suites via :yamerl, configured to build
  # strings (and therefore mapping keys) as binaries —
  # `str_node_as_binary` removes the charlist/sequence ambiguity
  # entirely. Normalization then only has to:
  #
  #   * turn YAML mappings (yamerl proplists of `{binary_key, value}`)
  #     into Elixir maps
  #   * turn `:null` into `nil`
  #
  # Sequences stay lists; numbers and booleans pass through unchanged.
  #
  # ## Lone-surrogate healing
  #
  # One upstream case (`agent/legacy/streaming_parser.yaml`,
  # `test_stream_cut_escape_sequence_*`) expresses an interim expected
  # value as `"Rocket \\ud83d"` — an *unpaired* UTF-16 surrogate escape
  # inside a double-quoted YAML scalar. Python's harness survives it
  # because Python strings can hold lone surrogates; UTF-8 binaries
  # cannot, so yamerl (correctly) rejects it.
  #
  # Before parsing we rewrite **unpaired** surrogate escapes
  # (`\\uD800`–`\\uDBFF` not followed by its low pair, or a lone low
  # `\\uDC00`–`\\uDFFF`) **inside double-quoted scalars only** into
  # escaped-literal form (`\\\\ud83d` ⇒ the six characters `\\` `u` `d`
  # `8` `3` `d`). That is precisely the healing semantics our
  # streaming parser (phase 10) implements for a JSON string cut
  # mid-escape: emit the partial escape as literal text until the
  # sequence completes. Paired escapes and valid code points are left
  # untouched. Block scalars and comments are tracked so quotes inside
  # them never trigger healing.

  @decode_options [:str_node_as_binary]

  @block_indicator ~r/:\s*[|>][0-9]*[+-]?\s*$/

  @doc """
  Decodes a YAML string into a list of normalized documents.
  """
  @spec decode_string(String.t()) :: {:ok, [term()]} | {:error, term()}
  def decode_string(yaml) when is_binary(yaml) do
    healed = heal_lone_surrogate_escapes(yaml)

    {:ok, :yamerl.decode(to_charlist(healed), @decode_options) |> Enum.map(&normalize/1)}
  catch
    :error, reason -> {:error, reason}
  end

  # -------------------------------------------------------------- healing --

  @doc false
  @spec heal_lone_surrogate_escapes(String.t()) :: String.t()
  def heal_lone_surrogate_escapes(yaml) do
    {lines, _block} =
      yaml
      |> String.split("\n")
      |> Enum.map_reduce(nil, &heal_line/2)

    Enum.join(lines, "\n")
  end

  # Block-scalar state: `nil` outside blocks, or the block's indent while
  # inside. A line inside a block whose indent is ≤ the opener's, or a
  # document marker, ends the block.
  defp heal_line(line, block) do
    cond do
      block != nil and inside_block?(line, block) ->
        {line, block}

      block != nil ->
        heal_line(line, nil)

      Regex.match?(@block_indicator, line) ->
        {line, %{indent: indent_of(line)}}

      true ->
        {scan_line(line, false, ""), nil}
    end
  end

  defp inside_block?("", _block), do: true

  defp inside_block?(line, block),
    do: line =~ ~r/^\s*$/ or indent_of(line) > block.indent

  defp indent_of(line), do: line |> String.split(~r/\S/u, parts: 2) |> hd() |> byte_size()

  # In-line scanner: tracks double-quoted scalars; rewrites lone
  # surrogate `\\uXXXX` escapes inside them. Everything else passes
  # through byte-for-byte.
  defp scan_line(<<>>, _in_dq?, acc), do: acc

  # A `#` outside a quoted scalar (at line start or after whitespace)
  # starts a comment — the rest of the line is literal.
  defp scan_line(<<?#, rest::binary>>, false, acc)
       when acc == "" or acc in [<<" ">>, <<"\t">>] or
              binary_part(acc, byte_size(acc) - 1, 1) in [<<" ">>, <<"\t">>],
       do: acc <> "#" <> rest

  defp scan_line(<<?", rest::binary>>, in_dq?, acc),
    do: scan_line(rest, not in_dq?, acc <> <<?">>)

  defp scan_line(<<?\\, ?u, hex::binary-size(4), rest::binary>>, true, acc) do
    code = String.to_integer(hex, 16)

    cond do
      code not in 0xD800..0xDFFF ->
        scan_line(rest, true, acc <> "\\u" <> hex)

      high_surrogate?(code) and paired_low?(rest) ->
        <<low::binary-size(6), rest2::binary>> = rest
        scan_line(rest2, true, acc <> "\\u" <> hex <> low)

      true ->
        # Lone surrogate: escape the backslash so the escape sequence
        # becomes literal text (`\\ud83d` — six characters).
        scan_line(rest, true, acc <> "\\\\u" <> hex)
    end
  end

  defp scan_line(<<?\\, ?U, hex::binary-size(8), rest::binary>>, true, acc) do
    code = String.to_integer(hex, 16)

    if code in 0xD800..0xDFFF do
      scan_line(rest, true, acc <> "\\\\U" <> hex)
    else
      scan_line(rest, true, acc <> "\\U" <> hex)
    end
  end

  defp scan_line(<<?\\, c::binary-size(1), rest::binary>>, true, acc),
    do: scan_line(rest, true, acc <> "\\" <> c)

  defp scan_line(<<c::binary-size(1), rest::binary>>, in_dq?, acc),
    do: scan_line(rest, in_dq?, acc <> c)

  defp high_surrogate?(code), do: code in 0xD800..0xDBFF

  defp paired_low?(<<"\\u", low::binary-size(4), _::binary>>) do
    String.to_integer(low, 16) in 0xDC00..0xDFFF
  end

  defp paired_low?(_), do: false

  # ------------------------------------------------------------ normalize --

  @doc """
  Loads a YAML file, returning its normalized documents.
  """
  @spec load_file(Path.t()) :: {:ok, [term()]} | {:error, term()}
  def load_file(path) do
    case File.read(path) do
      {:ok, contents} -> decode_string(contents)
      {:error, reason} -> {:error, reason}
    end
  end

  @doc false
  @spec normalize(term()) :: term()
  def normalize(entries) when is_list(entries) do
    if mapping?(entries) do
      Map.new(entries, fn {key, value} -> {key, normalize(value)} end)
    else
      Enum.map(entries, &normalize/1)
    end
  end

  def normalize(:null), do: nil
  def normalize(value), do: value

  @spec mapping?(term()) :: boolean()
  defp mapping?(entries) do
    entries != [] and
      Enum.all?(entries, fn
        {key, _value} when is_binary(key) -> true
        _other -> false
      end)
  end
end

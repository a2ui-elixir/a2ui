defmodule A2UIAgent.DirectJson.JsonReader do
  @moduledoc """
  Reads the JSON a model writes, which is often almost JSON.

  Both readers accept what a model commonly gets wrong and a strict
  decoder rejects: a trailing comma before `]` or `}`, and a raw line
  break or tab inside a string. When the text does not read as it is,
  they read it again with curly quotes straightened, so a curly quote
  inside a string that is otherwise valid JSON is kept.

      iex> A2UIAgent.DirectJson.JsonReader.read(~s([{"a": 1,},]))
      {:ok, [%{"a" => 1}]}

  `read_partial_items/3` reads a message list that is still arriving. It
  returns the messages read so far, each with whether its text was
  complete. An unfinished message is healed where that is safe: an open
  object or array is closed, and a string under one of the
  `progressive_keys` is cut where the text ends (unless it starts like a
  URL, which would name the wrong resource). Under one of the
  `whole_item_keys`, an array keeps only its finished items.

      iex> A2UIAgent.DirectJson.JsonReader.read_partial_items(
      ...>   ~s([{"id": "a", "text": "Hel), ["text"])
      [{%{"id" => "a", "text" => "Hel"}, false}]

  A `\\u` escape of an unpaired surrogate reads as U+FFFD, since an
  Elixir string cannot hold a lone surrogate.
  """

  @moduledoc since: "0.1.0"

  @url_prefixes ["http://", "https://", "data:"]

  @doc """
  Reads the complete JSON document `text`.
  """
  @spec read(String.t()) :: {:ok, term()} | {:error, String.t()}
  def read(text) when is_binary(text) do
    case document(text) do
      {:ok, value} ->
        {:ok, value}

      {:error, _reason} = error ->
        straight = straighten_quotes(text)
        if straight == text, do: error, else: document(straight)
    end
  end

  @doc """
  Reads a partial JSON array (or a single object) of messages into
  `{message, closed?}` pairs. Text that cannot be read gives `[]`.
  """
  @spec read_partial_items(String.t(), Enumerable.t(), Enumerable.t()) :: [{term(), boolean()}]
  def read_partial_items(text, progressive_keys, whole_item_keys \\ []) when is_binary(text) do
    state = %{
      partial: true,
      progressive: MapSet.new(progressive_keys),
      whole: MapSet.new(whole_item_keys),
      cut: false
    }

    case run(text, fn -> message_items(text, state) end) do
      {:ok, items} -> items
      {:error, _reason} -> read_straightened(text, state)
    end
  end

  defp read_straightened(text, state) do
    straight = straighten_quotes(text)

    with true <- straight != text,
         {:ok, items} <- run(straight, fn -> message_items(straight, state) end) do
      items
    else
      _unreadable -> []
    end
  end

  defp straighten_quotes(text) do
    text
    |> String.replace(["“", "”"], "\"")
    |> String.replace(["‘", "’"], "'")
  end

  # -- entry points ---------------------------------------------------------------

  defp document(text) do
    state = %{partial: false, progressive: MapSet.new(), whole: MapSet.new(), cut: false}

    run(text, fn ->
      {value, rest, _state} = value(skip_space(text), state, false)
      rest = skip_space(rest)
      if rest != "", do: fail(rest, "unexpected text after the JSON value")
      value
    end)
  end

  defp run(text, fun) do
    {:ok, fun.()}
  catch
    {:json_fail, rest, reason} -> {:error, "Invalid JSON at #{position(text, rest)}: #{reason}"}
  end

  defp position(text, rest),
    do: text |> binary_part(0, byte_size(text) - byte_size(rest)) |> String.length()

  defp message_items(text, state) do
    case skip_space(text) do
      "" -> []
      "[" <> rest -> items(rest, state, [])
      rest -> single_item(rest, state)
    end
  end

  defp single_item(rest, state) do
    case attempt(fn -> value(rest, %{state | cut: false}, false) end) do
      :unfinished ->
        []

      {message, rest, state} ->
        rest = skip_space(rest)
        if rest != "", do: fail(rest, "unexpected text after the JSON value")
        [{message, not state.cut}]
    end
  end

  defp items(rest, state, acc) do
    case skip_space(rest) do
      "" ->
        Enum.reverse(acc)

      "]" <> after_list ->
        after_list = skip_space(after_list)
        if after_list != "", do: fail(after_list, "unexpected text after the JSON value")
        Enum.reverse(acc)

      rest ->
        item(rest, state, acc)
    end
  end

  defp item(rest, state, acc) do
    case attempt(fn -> value(rest, %{state | cut: false}, false) end) do
      :unfinished -> Enum.reverse(acc)
      {message, rest, state} -> next_item(rest, state, [{message, not state.cut} | acc])
    end
  end

  defp next_item(rest, state, acc) do
    case skip_space(rest) do
      "" -> Enum.reverse(acc)
      "," <> rest -> items(rest, state, acc)
      "]" <> _ = rest -> items(rest, state, acc)
      rest -> fail(rest, "expected ',' or ']'")
    end
  end

  defp attempt(fun) do
    fun.()
  catch
    :unfinished -> :unfinished
  end

  # -- values ---------------------------------------------------------------------

  defp value("", state, _healable), do: unfinished("", state)
  defp value("{" <> rest, state, _healable), do: object(rest, state, %{})
  defp value("[" <> rest, state, _healable), do: array(rest, state, false, [])
  defp value("\"" <> rest, state, healable), do: string(rest, state, healable, [])

  defp value(<<c, _::binary>> = rest, state, _healable) when c == ?- or c in ?0..?9,
    do: number(rest, state)

  defp value(rest, state, _healable), do: literal(rest, state)

  defp literal(rest, state) do
    Enum.find_value([{"true", true}, {"false", false}, {"null", nil}], fn {word, value} ->
      cond do
        String.starts_with?(rest, word) ->
          {value, binary_part(rest, byte_size(word), byte_size(rest) - byte_size(word)), state}

        state.partial and String.starts_with?(word, rest) ->
          unfinished(rest, state)

        true ->
          nil
      end
    end) || fail(rest, "unexpected character '#{String.first(rest)}'")
  end

  defp object(rest, state, object) do
    case skip_space(rest) do
      "" -> healed(object, "", state)
      "}" <> rest -> {object, rest, state}
      "\"" <> rest -> member(rest, state, object)
      rest -> fail(rest, "expected a key")
    end
  end

  defp member(rest, state, object) do
    {key, rest, state} = string(rest, state, false, [])

    case skip_space(rest) do
      "" ->
        unfinished("", state)

      ":" <> rest ->
        {value, rest, state} = member_value(skip_space(rest), key, state)
        object = Map.put(object, key, value)

        case skip_space(rest) do
          "" -> healed(object, "", state)
          "," <> rest -> object(rest, state, object)
          "}" <> _ = rest -> object(rest, state, object)
          rest -> fail(rest, "expected ',' or '}'")
        end

      rest ->
        fail(rest, "expected ':' after key '#{key}'")
    end
  end

  defp member_value("[" <> rest, key, %{partial: true} = state) do
    if MapSet.member?(state.whole, key),
      do: array(rest, state, true, []),
      else: value("[" <> rest, state, MapSet.member?(state.progressive, key))
  end

  defp member_value(rest, key, state),
    do: value(rest, state, state.partial and MapSet.member?(state.progressive, key))

  defp array(rest, state, whole_items?, acc) do
    case skip_space(rest) do
      "" ->
        healed(Enum.reverse(acc), "", state)

      "]" <> rest ->
        {Enum.reverse(acc), rest, state}

      rest when whole_items? ->
        whole_item(rest, state, acc)

      rest ->
        {item, rest, state} = value(rest, state, false)
        next_element(rest, state, false, [item | acc])
    end
  end

  # An item the text cuts short ends a whole-item array before it.
  defp whole_item(rest, state, acc) do
    cut_before = state.cut

    case attempt(fn -> value(rest, %{state | cut: false}, false) end) do
      :unfinished -> healed(Enum.reverse(acc), "", state)
      {_item, rest, %{cut: true} = state} -> healed(Enum.reverse(acc), rest, state)
      {item, rest, state} -> next_element(rest, %{state | cut: cut_before}, true, [item | acc])
    end
  end

  defp next_element(rest, state, whole_items?, acc) do
    case skip_space(rest) do
      "" -> healed(Enum.reverse(acc), "", state)
      "," <> rest -> array(rest, state, whole_items?, acc)
      "]" <> _ = rest -> array(rest, state, whole_items?, acc)
      rest -> fail(rest, "expected ',' or ']'")
    end
  end

  defp healed(value, rest, %{partial: true} = state), do: {value, rest, %{state | cut: true}}
  defp healed(_value, rest, state), do: unfinished(rest, state)

  # -- strings --------------------------------------------------------------------

  defp string("", state, healable, buffer), do: string_end(state, healable, buffer)
  defp string("\"" <> rest, state, _healable, buffer), do: {join(buffer), rest, state}
  defp string("\\", state, healable, buffer), do: string_end(state, healable, buffer)

  defp string("\\" <> <<escaped::utf8, after_escape::binary>> = rest, state, healable, buffer) do
    case escaped do
      ?u -> unicode(rest, state, healable, buffer)
      _ -> string(after_escape, state, healable, [buffer, simple_escape(escaped, rest)])
    end
  end

  defp string(rest, state, healable, buffer) do
    case :binary.match(rest, ["\"", "\\"]) do
      {0, _length} ->
        # An invalid UTF-8 sequence right after a backslash.
        fail(rest, "invalid escape")

      {at, _length} ->
        string(
          binary_part(rest, at, byte_size(rest) - at),
          state,
          healable,
          [buffer, binary_part(rest, 0, at)]
        )

      :nomatch ->
        string("", state, healable, [buffer, rest])
    end
  end

  defp simple_escape(escaped, _rest) when escaped in [?", ?\\, ?/], do: <<escaped>>
  defp simple_escape(?b, _rest), do: "\b"
  defp simple_escape(?f, _rest), do: "\f"
  defp simple_escape(?n, _rest), do: "\n"
  defp simple_escape(?r, _rest), do: "\r"
  defp simple_escape(?t, _rest), do: "\t"
  defp simple_escape(escaped, rest), do: fail(rest, "invalid escape '\\#{<<escaped::utf8>>}'")

  # `rest` starts with the backslash of a `\uXXXX` escape. An escape the
  # text cuts short ends the text; a high surrogate whose low half the
  # partial text cuts off is dropped, so the string heals before it.
  defp unicode(rest, state, healable, buffer) when byte_size(rest) < 6,
    do: string_end(state, healable, buffer)

  defp unicode(
         <<_::binary-size(2), hex::binary-size(4), after_escape::binary>> = rest,
         state,
         healable,
         buffer
       ) do
    code = hex_code(hex, rest)

    cond do
      code in 0xD800..0xDBFF and cut_low_half?(after_escape, state) ->
        string_end(state, healable, buffer)

      code in 0xD800..0xDBFF ->
        high_surrogate(code, after_escape, rest, state, healable, buffer)

      code in 0xDC00..0xDFFF ->
        string(after_escape, state, healable, [buffer, "�"])

      true ->
        string(after_escape, state, healable, [buffer, <<code::utf8>>])
    end
  end

  defp cut_low_half?(after_escape, %{partial: true}) when byte_size(after_escape) < 6,
    do: String.starts_with?("\\u", after_escape) or String.starts_with?(after_escape, "\\u")

  defp cut_low_half?(_after_escape, _state), do: false

  defp high_surrogate(
         code,
         "\\u" <> <<low_hex::binary-size(4), after_low::binary>>,
         rest,
         state,
         healable,
         buffer
       ) do
    low = hex_code(low_hex, rest)

    if low in 0xDC00..0xDFFF do
      combined = 0x10000 + Bitwise.bsl(code - 0xD800, 10) + (low - 0xDC00)
      string(after_low, state, healable, [buffer, <<combined::utf8>>])
    else
      string("\\u" <> low_hex <> after_low, state, healable, [buffer, "�"])
    end
  end

  defp high_surrogate(_code, after_escape, _rest, state, healable, buffer),
    do: string(after_escape, state, healable, [buffer, "�"])

  defp hex_code(hex, rest) do
    case Integer.parse(hex, 16) do
      {code, ""} when code >= 0 -> code
      _invalid -> fail(rest, "invalid unicode escape")
    end
  end

  defp string_end(%{partial: true} = state, true, buffer) do
    value = join(buffer)

    if String.starts_with?(value, @url_prefixes),
      do: unfinished("", state),
      else: {value, "", %{state | cut: true}}
  end

  defp string_end(state, _healable, _buffer), do: unfinished("", state)

  defp join(buffer), do: IO.iodata_to_binary(buffer)

  # -- numbers --------------------------------------------------------------------

  defp number(rest, state) do
    {literal, after_number} = take_number(rest)

    if after_number == "" and state.partial, do: unfinished("", state)

    if Regex.match?(~r/\A-?(0|[1-9][0-9]*)(\.[0-9]+)?([eE][+-]?[0-9]+)?\z/, literal),
      do: {to_number(literal), after_number, state},
      else: fail(rest, "invalid number '#{literal}'")
  end

  defp take_number("-" <> rest) do
    {digits, after_number} = take_number_chars(rest, [])
    {"-" <> digits, after_number}
  end

  defp take_number(rest), do: take_number_chars(rest, [])

  defp take_number_chars(<<c, rest::binary>>, acc) when c in ?0..?9 or c in ~c"+-.eE",
    do: take_number_chars(rest, [acc, c])

  defp take_number_chars(rest, acc), do: {IO.iodata_to_binary(acc), rest}

  defp to_number(literal) do
    if String.contains?(literal, [".", "e", "E"]) do
      {float, ""} = Float.parse(normalize_float(literal))
      float
    else
      String.to_integer(literal)
    end
  end

  # `Float.parse/1` needs a fraction before an exponent: "1e5" -> "1.0e5".
  defp normalize_float(literal) do
    if String.contains?(literal, "."),
      do: literal,
      else: String.replace(literal, ~r/[eE]/, ".0e", global: false)
  end

  # -- helpers --------------------------------------------------------------------

  defp skip_space(<<c, rest::binary>>) when c in [?\s, ?\t, ?\n, ?\r], do: skip_space(rest)
  defp skip_space(rest), do: rest

  @spec unfinished(String.t(), map()) :: no_return()
  defp unfinished(_rest, %{partial: true}), do: throw(:unfinished)
  defp unfinished(rest, _state), do: fail(rest, "unexpected end of the JSON text")

  @spec fail(String.t(), String.t()) :: no_return()
  defp fail(rest, reason), do: throw({:json_fail, rest, reason})
end

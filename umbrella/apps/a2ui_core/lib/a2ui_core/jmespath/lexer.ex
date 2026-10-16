defmodule A2UICore.JMESPath.Lexer do
  @moduledoc false

  # Tokens of a JMESPath expression: `{type, value, position}`, ending
  # with `{:eof, nil, position}`. Errors are thrown as
  # `{:jmespath, code, message}` (see A2UICore.JMESPath).

  @simple %{
    ?. => :dot,
    ?* => :star,
    ?] => :rbracket,
    ?, => :comma,
    ?: => :colon,
    ?@ => :current,
    ?( => :lparen,
    ?) => :rparen,
    ?{ => :lbrace,
    ?} => :rbrace
  }

  @two_char %{
    "[]" => :flatten,
    "[?" => :filter,
    "||" => :or,
    "&&" => :and,
    "<=" => :lte,
    ">=" => :gte,
    "!=" => :ne,
    "==" => :eq
  }

  @one_char %{?[ => :lbracket, ?| => :pipe, ?& => :expref, ?< => :lt, ?> => :gt, ?! => :not}

  @type token :: {atom(), term(), non_neg_integer()}

  @spec tokenize(String.t()) :: [token()]
  def tokenize(expression), do: lex(expression, 0, [])

  defp lex(<<>>, pos, acc), do: Enum.reverse([{:eof, nil, pos} | acc])

  defp lex(<<c, rest::binary>>, pos, acc) when c in [?\s, ?\t, ?\n, ?\r],
    do: lex(rest, pos + 1, acc)

  defp lex(<<c, rest::binary>>, pos, acc) when is_map_key(@simple, c),
    do: lex(rest, pos + 1, [{Map.fetch!(@simple, c), <<c>>, pos} | acc])

  defp lex(<<pair::binary-size(2), rest::binary>>, pos, acc) when is_map_key(@two_char, pair),
    do: lex(rest, pos + 2, [{Map.fetch!(@two_char, pair), pair, pos} | acc])

  defp lex(<<c, rest::binary>>, pos, acc) when is_map_key(@one_char, c),
    do: lex(rest, pos + 1, [{Map.fetch!(@one_char, c), <<c>>, pos} | acc])

  defp lex(<<c, _::binary>> = input, pos, acc)
       when c in ?a..?z or c in ?A..?Z or c == ?_ do
    {name, rest} = take_while(input, &identifier_char?/1)
    lex(rest, pos + byte_size(name), [{:unquoted_identifier, name, pos} | acc])
  end

  defp lex(<<c, _::binary>> = input, pos, acc) when c in ?0..?9, do: number(input, pos, acc)

  defp lex(<<?-, c, _::binary>> = input, pos, acc) when c in ?0..?9, do: number(input, pos, acc)

  defp lex(<<?", _::binary>> = input, pos, acc) do
    {lexeme, rest, length} = delimited(input, ?", pos)

    case Jason.decode(<<?">> <> lexeme <> <<?">>) do
      {:ok, name} -> lex(rest, pos + length, [{:quoted_identifier, name, pos} | acc])
      {:error, _} -> syntax!("Invalid quoted identifier at position #{pos}")
    end
  end

  defp lex(<<?', _::binary>> = input, pos, acc) do
    {lexeme, rest, length} = delimited(input, ?', pos)
    value = String.replace(lexeme, "\\'", "'")
    lex(rest, pos + length, [{:literal, value, pos} | acc])
  end

  defp lex(<<?`, _::binary>> = input, pos, acc) do
    {lexeme, rest, length} = delimited(input, ?`, pos)

    lex(rest, pos + length, [
      {:literal, literal(String.replace(lexeme, "\\`", "`"), pos), pos} | acc
    ])
  end

  defp lex(<<c::utf8, _::binary>>, pos, _acc),
    do: syntax!("Unknown token '#{<<c::utf8>>}' at position #{pos}")

  defp lex(<<c, _::binary>>, pos, _acc),
    do: syntax!("Unknown byte #{c} at position #{pos}")

  defp number(<<sign, rest::binary>>, pos, acc) do
    {digits, rest} =
      if sign == ?-,
        do: take_while(rest, &(&1 in ?0..?9)),
        else: take_while(<<sign, rest::binary>>, &(&1 in ?0..?9))

    text = if sign == ?-, do: "-" <> digits, else: digits
    lex(rest, pos + byte_size(text), [{:number, String.to_integer(text), pos} | acc])
  end

  # A JSON value; text that is not JSON is a string (the deprecated form
  # of string literals).
  defp literal(lexeme, pos) do
    case Jason.decode(lexeme) do
      {:ok, value} ->
        value

      {:error, _} ->
        case Jason.decode(<<?">> <> String.trim_leading(lexeme) <> <<?">>) do
          {:ok, value} -> value
          {:error, _} -> syntax!("Invalid literal at position #{pos}")
        end
    end
  end

  # The text between a delimiter and its unescaped closing match; a
  # backslash keeps the character after it (both are kept).
  defp delimited(<<delimiter, rest::binary>>, delimiter, pos) do
    case until(rest, delimiter, []) do
      {:ok, lexeme, rest} -> {lexeme, rest, byte_size(lexeme) + 2}
      :unclosed -> syntax!("Unclosed #{<<delimiter>>} delimiter at position #{pos}")
    end
  end

  defp until(<<delimiter, rest::binary>>, delimiter, acc),
    do: {:ok, acc |> Enum.reverse() |> IO.iodata_to_binary(), rest}

  defp until(<<?\\, c::utf8, rest::binary>>, delimiter, acc),
    do: until(rest, delimiter, [<<?\\, c::utf8>> | acc])

  defp until(<<c::utf8, rest::binary>>, delimiter, acc),
    do: until(rest, delimiter, [<<c::utf8>> | acc])

  defp until(_rest, _delimiter, _acc), do: :unclosed

  defp take_while(input, keep?), do: take_while(input, keep?, 0)

  defp take_while(input, keep?, at) do
    case input do
      <<_::binary-size(^at), c, _::binary>> ->
        if keep?.(c), do: take_while(input, keep?, at + 1), else: split(input, at)

      _end ->
        split(input, at)
    end
  end

  defp split(input, at) do
    <<taken::binary-size(^at), rest::binary>> = input
    {taken, rest}
  end

  defp identifier_char?(c), do: c in ?a..?z or c in ?A..?Z or c in ?0..?9 or c == ?_

  @spec syntax!(String.t()) :: no_return()
  defp syntax!(message), do: throw({:jmespath, "syntax", message})
end

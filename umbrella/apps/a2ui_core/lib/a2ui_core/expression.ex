defmodule A2UICore.Expression do
  @moduledoc """
  Parser for A2UI expression templates — the `${…}` interpolation
  language used by `formatString` and by dynamic string values.

  `parse/1` turns a template into a list of *parts*:

    * literal text (a string),
    * a literal value from inside an interpolation: a string (`'x'`,
      `"x"`), a number (`42`, `-1.5`, `1e5`) or a boolean,
    * a data binding `%{"path" => path}` (`${/user/name}`, `${count}`),
    * a function call `%{"call" => name, "args" => %{…}, "returnType" => "any"}`
      (`${add(a: 1, b: /x)}`); arguments are themselves expressions. A
      system function is named with `@` and must be called:
      `${@index(offset: 1)}`.

  `\\${` is an escaped marker and yields the literal `${`. `null` yields
  nothing. Whitespace inside an interpolation is ignored.

  Limits (shared by every reference engine so they accept the same
  inputs): templates up to 10 000 characters, 1 000 parts, nesting
  depth 100.

  Errors are `{:error, %A2UICore.Error{category: :expression}}`:
  unclosed interpolation, a missing `:` or `)` in a call, trailing
  characters, an invalid or out-of-range number literal, and exceeded
  limits.

      iex> A2UICore.Expression.parse("Hello, ${/user/name}!")
      {:ok, ["Hello, ", %{"path" => "/user/name"}, "!"]}
      iex> A2UICore.Expression.parse("${add(a: 1, b: 2)}")
      {:ok, [%{"call" => "add", "args" => %{"a" => 1, "b" => 2}, "returnType" => "any"}]}
      iex> {:error, error} = A2UICore.Expression.parse("${oops")
      iex> error.message
      "Unclosed interpolation: missing '}'"
  """

  alias A2UICore.Error
  alias A2UICore.Identifier

  @moduledoc since: "0.1.0"

  @max_depth 100
  @max_template_length 10_000
  @max_parts 1_000

  # `[0-9]` rather than `\d`: Unicode digits are not number characters.
  @number_literal ~r/\A[+-]?(?:[0-9]+\.?[0-9]*|\.[0-9]+)(?:[eE][+-]?[0-9]+)?\z/

  # Round-half-even sends anything at or above this to infinity.
  @double_overflow Integer.pow(2, 1024) - Integer.pow(2, 970)

  @typedoc "One element of a parsed template."
  @type part :: String.t() | number() | boolean() | map()

  @doc """
  The recursion limit for nested interpolations and call arguments.
  """
  @spec max_depth() :: pos_integer()
  def max_depth, do: @max_depth

  @doc """
  Parses a template into parts. Adjacent literal runs may be split
  across several string parts; join them to compare.
  """
  @spec parse(String.t()) :: {:ok, [part()]} | {:error, Error.t()}
  def parse(template) when is_binary(template) do
    {:ok, template(template)}
  catch
    {:expression_error, message} ->
      {:error, Error.new(:expression, "EXPRESSION_ERROR", message)}
  end

  @doc """
  Like `parse/1`, raising `A2UICore.Error` on failure.
  """
  @spec parse!(String.t()) :: [part()]
  def parse!(template) do
    case parse(template) do
      {:ok, parts} -> parts
      {:error, error} -> raise error
    end
  end

  # -- template level ----------------------------------------------------------------

  defp template(input) do
    cond do
      too_long?(input) ->
        fail(
          "Expression template length (#{codepoint_count(input)}) exceeds maximum " <>
            "limit (#{@max_template_length})"
        )

      input == "" ->
        []

      not String.contains?(input, "${") ->
        [input]

      true ->
        input |> segments(0, [], 0) |> Enum.reverse() |> Enum.reject(&(&1 == ""))
    end
  end

  defp segments("", _depth, parts, _count), do: parts

  defp segments(_input, _depth, _parts, count) when count >= @max_parts,
    do: fail("Expression parts count exceeds maximum limit (#{@max_parts})")

  defp segments("${" <> rest, depth, parts, count) do
    {content, rest} = interpolation_content(rest)

    case expression(content, depth + 1) do
      "" -> segments(rest, depth, parts, count)
      parsed -> segments(rest, depth, [parsed | parts], count + 1)
    end
  end

  defp segments("\\${" <> rest, depth, parts, count),
    do: segments(rest, depth, ["${" | parts], count + 1)

  defp segments(input, depth, parts, count) do
    {text, rest} = literal_run(input)
    segments(rest, depth, [text | parts], count + 1)
  end

  # Text up to the next `${` or `\${`. Always consumes at least one character
  # (the caller has ruled out both markers at the start).
  defp literal_run(input), do: literal_run(input, 0)

  defp literal_run(input, offset) do
    case binary_part(input, offset, byte_size(input) - offset) do
      "" -> {input, ""}
      "${" <> _ when offset > 0 -> split(input, offset)
      "\\${" <> _ when offset > 0 -> split(input, offset)
      <<_::utf8, _::binary>> = tail -> literal_run(input, offset + char_size(tail))
      <<_, _::binary>> -> literal_run(input, offset + 1)
    end
  end

  defp split(input, offset),
    do: {binary_part(input, 0, offset), binary_part(input, offset, byte_size(input) - offset)}

  defp char_size(<<c::utf8, _::binary>>), do: byte_size(<<c::utf8>>)

  # The text between `${` and its matching `}`, honouring nested braces and
  # quoted strings; the second element is what follows the `}`.
  defp interpolation_content(input), do: interpolation_content(input, 0, 1)

  defp interpolation_content(input, offset, 0) do
    {binary_part(input, 0, offset - 1), binary_part(input, offset, byte_size(input) - offset)}
  end

  defp interpolation_content(input, offset, _balance) when offset >= byte_size(input),
    do: fail("Unclosed interpolation: missing '}'")

  defp interpolation_content(input, offset, balance) do
    case :binary.at(input, offset) do
      ?{ -> interpolation_content(input, offset + 1, balance + 1)
      ?} -> interpolation_content(input, offset + 1, balance - 1)
      quote when quote in [?', ?"] -> skip_quoted(input, offset + 1, quote, balance)
      _ -> interpolation_content(input, offset + 1, balance)
    end
  end

  defp skip_quoted(input, offset, _quote, balance) when offset >= byte_size(input),
    do: interpolation_content(input, offset, balance)

  defp skip_quoted(input, offset, quote, balance) do
    case :binary.at(input, offset) do
      ?\\ -> skip_quoted(input, offset + 2, quote, balance)
      ^quote -> interpolation_content(input, offset + 1, balance)
      _ -> skip_quoted(input, offset + 1, quote, balance)
    end
  end

  # -- expressions ---------------------------------------------------------------------

  # The value of the text inside one interpolation. `""` means "no part".
  defp expression(_content, depth) when depth > @max_depth,
    do: fail("Max recursion depth reached in parse")

  defp expression(content, depth) do
    case String.trim(content) do
      "" ->
        ""

      trimmed ->
        {value, rest} = value(trimmed, depth)

        if rest == "",
          do: value,
          else: fail("Unexpected characters at end of expression: '#{rest}'")
    end
  end

  # Both recursive paths — nested interpolations and call arguments —
  # pass through here, so the depth check counts both.
  defp value(_input, depth) when depth > @max_depth,
    do: fail("Max recursion depth reached in parse")

  defp value(input, depth) do
    case String.trim_leading(input) do
      "" -> {"", ""}
      "${" <> rest -> nested_interpolation(rest, depth)
      <<quote, _::binary>> = text when quote in [?', ?"] -> string_literal(text)
      text -> scalar(text, depth)
    end
  end

  defp nested_interpolation(rest, depth) do
    {content, rest} = interpolation_content(rest)
    {expression(content, depth + 1), rest}
  end

  defp scalar(text, depth) do
    cond do
      number_start?(text) -> number_literal(text)
      match = keyword(text, "true") -> {true, match}
      match = keyword(text, "false") -> {false, match}
      match = keyword(text, "null") -> {"", match}
      true -> path_or_call(text, depth)
    end
  end

  defp keyword(text, word) do
    if String.starts_with?(text, word) do
      rest = binary_part(text, byte_size(word), byte_size(text) - byte_size(word))
      if continues?(rest), do: nil, else: rest
    end
  end

  defp continues?(<<c::utf8, _::binary>>), do: Identifier.continue?(<<c::utf8>>)
  defp continues?(_), do: false

  # -- paths and calls ---------------------------------------------------------------------

  # A system function (`@index`) is named by `@` and an ASCII
  # identifier, and is always called.
  defp path_or_call("@" <> name_and_rest, depth) do
    case take_while(name_and_rest, &system_name_char?/1) do
      {<<first, _::binary>> = name, rest}
      when first in ?a..?z or first in ?A..?Z or first == ?_ ->
        system_call("@" <> name, String.trim_leading(rest), depth)

      _other ->
        fail("Invalid identifier starting with '@' in expression")
    end
  end

  defp path_or_call(text, depth) do
    {token, rest} = take_while(text, &path_char?/1)
    rest_trimmed = String.trim_leading(rest)

    case rest_trimmed do
      "(" <> after_paren -> function_call(token, after_paren, depth)
      _ when token == "" -> {"", rest_trimmed}
      _ -> {%{"path" => token}, rest_trimmed}
    end
  end

  defp system_call(name, "(" <> after_paren, depth), do: function_call(name, after_paren, depth)
  defp system_call(name, _rest, _depth), do: fail("Expected '(' after function name '#{name}'")

  defp path_char?(c), do: Identifier.continue?(c) or c in ["/", ".", "-"]

  defp system_name_char?(<<c>>) when c in ?a..?z or c in ?A..?Z or c in ?0..?9 or c == ?_,
    do: true

  defp system_name_char?(_c), do: false

  defp function_call(name, input, depth) do
    {args, rest} = arguments(String.trim_leading(input), name, depth, %{})
    {%{"call" => name, "args" => args, "returnType" => "any"}, rest}
  end

  defp arguments(")" <> rest, _name, _depth, args), do: {args, rest}

  defp arguments("", name, _depth, _args),
    do: fail("Expected ')' after function arguments for '#{name}'")

  defp arguments(input, name, depth, args) do
    {arg_name, rest} = take_while(input, &Identifier.continue?/1)

    case String.trim_leading(rest) do
      ":" <> after_colon ->
        {arg_value, rest} = value(String.trim_leading(after_colon), depth + 1)
        rest = String.trim_leading(rest)
        arguments(skip_comma(rest), name, depth, Map.put(args, arg_name, arg_value))

      _ ->
        fail("Expected ':' after argument name '#{arg_name}' in function '#{name}'")
    end
  end

  defp skip_comma("," <> rest), do: String.trim_leading(rest)
  defp skip_comma(rest), do: rest

  # -- literals ------------------------------------------------------------------------------

  defp string_literal(<<quote, rest::binary>>), do: string_body(rest, quote, [])

  defp string_body("", _quote, acc), do: {acc |> Enum.reverse() |> IO.iodata_to_binary(), ""}

  defp string_body(<<quote, rest::binary>>, quote, acc),
    do: {acc |> Enum.reverse() |> IO.iodata_to_binary(), rest}

  defp string_body("\\", _quote, acc), do: {acc |> Enum.reverse() |> IO.iodata_to_binary(), ""}

  defp string_body(<<?\\, escaped::utf8, rest::binary>>, quote, acc) do
    char =
      case escaped do
        ?n -> "\n"
        ?t -> "\t"
        ?r -> "\r"
        other -> <<other::utf8>>
      end

    string_body(rest, quote, [char | acc])
  end

  defp string_body(<<c::utf8, rest::binary>>, quote, acc),
    do: string_body(rest, quote, [<<c::utf8>> | acc])

  defp string_body(<<byte, rest::binary>>, quote, acc),
    do: string_body(rest, quote, [<<byte>> | acc])

  # A number starts at a digit, at `.` + digit, or at a sign followed by
  # either. A `-` or `.` inside a path never gets here: the path scanner
  # consumes it as part of its token.
  defp number_start?(<<sign, rest::binary>>) when sign in [?-, ?+], do: unsigned_start?(rest)
  defp number_start?(text), do: unsigned_start?(text)

  defp unsigned_start?(<<d, _::binary>>) when d in ?0..?9, do: true
  defp unsigned_start?(<<?., d, _::binary>>) when d in ?0..?9, do: true
  defp unsigned_start?(_), do: false

  defp number_literal(text) do
    {sign, after_sign} =
      case text do
        <<s, rest::binary>> when s in [?-, ?+] -> {<<s>>, rest}
        _ -> {"", text}
      end

    {mantissa, after_mantissa} = take_while(after_sign, &(&1 in ~w(0 1 2 3 4 5 6 7 8 9 .)))
    {exponent, rest} = exponent(after_mantissa)
    literal = sign <> mantissa <> exponent

    if Regex.match?(@number_literal, literal),
      do: {number(literal, sign, mantissa, exponent), rest},
      else: fail("Invalid number literal: '#{literal}'")
  end

  # `1e`, `1e+` are consumed whole so they are reported as invalid literals
  # rather than leaving trailing characters.
  defp exponent(<<e, rest::binary>>) when e in [?e, ?E] do
    {sign, after_sign} =
      case rest do
        <<s, tail::binary>> when s in [?+, ?-] -> {<<s>>, tail}
        _ -> {"", rest}
      end

    {digits, tail} = take_while(after_sign, &(&1 in ~w(0 1 2 3 4 5 6 7 8 9)))
    {<<e>> <> sign <> digits, tail}
  end

  defp exponent(text), do: {"", text}

  defp number(literal, sign, mantissa, exponent) do
    if String.contains?(literal, ".") or exponent != "" do
      float(sign, mantissa, exponent, literal)
    else
      integer(sign, mantissa, literal)
    end
  end

  defp integer(sign, digits, literal) do
    value = String.to_integer(digits)

    cond do
      value >= @double_overflow -> fail("Number literal is out of range: '#{literal}'")
      sign == "-" -> -value
      true -> value
    end
  end

  defp float(sign, mantissa, exponent, literal) do
    {whole, fraction} =
      case String.split(mantissa, ".", parts: 2) do
        [whole, fraction] -> {whole, fraction}
        [whole] -> {whole, ""}
      end

    exp =
      case exponent do
        "" -> ""
        <<_e, rest::binary>> -> "e" <> rest
      end

    canonical =
      if(sign == "-", do: "-", else: "") <>
        if(whole == "", do: "0", else: whole) <>
        "." <> if(fraction == "", do: "0", else: fraction) <> exp

    try do
      String.to_float(canonical)
    rescue
      ArgumentError -> fail("Number literal is out of range: '#{literal}'")
    end
  end

  # -- helpers -------------------------------------------------------------------------------

  # Splits off the longest prefix of characters satisfying `fun` (applied to
  # one-character strings).
  defp take_while(input, fun), do: take_while(input, fun, 0)

  defp take_while(input, fun, offset) do
    tail = binary_part(input, offset, byte_size(input) - offset)

    case tail do
      <<c::utf8, _::binary>> ->
        char = <<c::utf8>>

        if fun.(char),
          do: take_while(input, fun, offset + byte_size(char)),
          else: split(input, offset)

      _ ->
        split(input, offset)
    end
  end

  defp too_long?(input),
    do: byte_size(input) > @max_template_length and codepoint_count(input) > @max_template_length

  defp codepoint_count(input), do: input |> String.to_charlist() |> length()

  defp fail(message), do: throw({:expression_error, message})
end

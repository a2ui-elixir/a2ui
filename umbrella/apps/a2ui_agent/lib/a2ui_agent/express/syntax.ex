defmodule A2UIAgent.Express.Syntax do
  @moduledoc """
  Reads Express source into statements, following the grammar
  `specification/inference_formats/express/Express.g4`.

      iex> A2UIAgent.Express.Syntax.parse(~s|root = Text("Hi", variant="h1")|)
      {:ok, [{:assign, "root", {:call, "Text", ["Hi"], [{"variant", "h1"}]}}], []}

  A statement is `{:assign, target, value}`, where the target is a
  variable name or a data path (`"$/a/b"`), or `{:expr, value}`. A value
  is a JSON literal (a string, number, boolean or `nil`), a list, or one
  of:

    * `{:map, pairs}` — a map literal, keys in source order;
    * `{:path, path}` — a data binding, `$/a/b` as `"/a/b"`;
    * `{:check, name, args}` — a check rule such as `?regex("^a")`;
    * `{:call, name, args, kwargs}` — a call, keyword arguments as
      pairs in source order;
    * `{:var, name}` — a variable reference;
    * `:skipped` — the `_` placeholder.

  A keyword argument or map key given twice keeps its first place and
  its last value.

  `parse/1` returns the statements before the first syntax error with
  the errors it found, each `{line, column, message, kind}` where `kind`
  is `:lexer` for a character no token starts with and `:parser`
  otherwise. Lines count from 1 and columns from 0.
  """

  @moduledoc since: "0.1.0"

  @typedoc "An Express value."
  @type value ::
          String.t()
          | number()
          | boolean()
          | nil
          | [value()]
          | {:map, [{String.t(), value()}]}
          | {:path, String.t()}
          | {:check, String.t(), [value()]}
          | {:call, String.t(), [value()], [{String.t(), value()}]}
          | {:var, String.t()}
          | :skipped

  @typedoc "An Express statement."
  @type statement :: {:assign, String.t(), value()} | {:expr, value()}

  @typedoc "A syntax error: line, column, message and the stage that found it."
  @type syntax_error :: {pos_integer(), non_neg_integer(), String.t(), :lexer | :parser}

  @reserved ~w(true false null _)

  @punctuation %{
    ?= => :eq,
    ?( => :lparen,
    ?) => :rparen,
    ?[ => :lbracket,
    ?] => :rbracket,
    ?{ => :lbrace,
    ?} => :rbrace,
    ?, => :comma,
    ?: => :colon
  }

  @doc """
  Parses `source`. Returns `{:ok, statements, errors}`: when `errors` is
  not empty, `statements` holds the statements that start on a line
  before the first error.
  """
  @spec parse(String.t()) :: {:ok, [statement()], [syntax_error()]}
  def parse(source) when is_binary(source) do
    {tokens, lexer_errors} = tokenize(source)
    {statements, parser_error} = statements(tokens, [])

    errors =
      Enum.sort_by(lexer_errors ++ List.wrap(parser_error), fn {line, column, _, _} ->
        {line, column}
      end)

    kept =
      case errors do
        [] -> statements
        [{line, _column, _message, _kind} | _] -> Enum.filter(statements, &(elem(&1, 1) < line))
      end

    {:ok, Enum.map(kept, &elem(&1, 0)), errors}
  end

  @doc """
  Whether `name` can be written as a bare Express identifier: it matches
  `[a-zA-Z_][a-zA-Z0-9_]*` and is not `true`, `false`, `null` or `_`.

      iex> A2UIAgent.Express.Syntax.identifier?("content_grid")
      true
      iex> A2UIAgent.Express.Syntax.identifier?("content-grid")
      false
  """
  @spec identifier?(term()) :: boolean()
  def identifier?(name) when is_binary(name),
    do: name not in @reserved and Regex.match?(~r/\A[a-zA-Z_][a-zA-Z0-9_]*\z/, name)

  def identifier?(_name), do: false

  # -- lexer --------------------------------------------------------------------------

  # A token is {type, value, line, column}.
  defp tokenize(source), do: lex(source, 1, 0, [], [])

  defp lex(<<>>, line, column, tokens, errors),
    do: {Enum.reverse([{:eof, nil, line, column} | tokens]), Enum.reverse(errors)}

  defp lex(<<char, rest::binary>>, line, column, tokens, errors) when char in [?\s, ?\t, ?;],
    do: lex(rest, line, column + 1, tokens, errors)

  defp lex(<<?\r, ?\n, rest::binary>>, line, _column, tokens, errors),
    do: lex(rest, line + 1, 0, tokens, errors)

  defp lex(<<char, rest::binary>>, line, _column, tokens, errors) when char in [?\r, ?\n],
    do: lex(rest, line + 1, 0, tokens, errors)

  defp lex(<<?#, _::binary>> = source, line, column, tokens, errors),
    do: line_comment(source, line, column, tokens, errors)

  defp lex(<<?/, ?/, _::binary>> = source, line, column, tokens, errors),
    do: line_comment(source, line, column, tokens, errors)

  defp lex(<<?/, ?*, rest::binary>> = source, line, column, tokens, errors) do
    case :binary.match(rest, "*/") do
      {at, 2} ->
        comment = binary_part(source, 0, at + 4)
        {line, column} = advance(comment, line, column)
        lex(binary_part(rest, at + 2, byte_size(rest) - at - 2), line, column, tokens, errors)

      :nomatch ->
        unrecognized(source, line, column, tokens, errors)
    end
  end

  defp lex(<<char, _::binary>> = source, line, column, tokens, errors)
       when char in [?r, ?R, ?"] do
    case string_token(source) do
      {length, value} -> emit(source, length, {:string, value}, line, column, tokens, errors)
      nil when char == ?" -> unrecognized(source, line, column, tokens, errors)
      nil -> word(source, line, column, tokens, errors)
    end
  end

  defp lex(<<?$, rest::binary>> = source, line, column, tokens, errors) do
    path = take_while(rest, &path_char?/1)
    emit(source, 1 + byte_size(path), {:path, path}, line, column, tokens, errors)
  end

  defp lex(<<??, first, _::binary>> = source, line, column, tokens, errors)
       when first in ?a..?z or first in ?A..?Z or first == ?_ do
    <<??, rest::binary>> = source
    name = take_while(rest, &word_char?/1)
    emit(source, 1 + byte_size(name), {:check, name}, line, column, tokens, errors)
  end

  defp lex(<<char, _::binary>> = source, line, column, tokens, errors)
       when char in ?0..?9 or char == ?- do
    case Regex.run(~r/\A-?[0-9]+(?:\.[0-9]+)?/, source) do
      [text] ->
        emit(source, byte_size(text), {:number, number(text)}, line, column, tokens, errors)

      nil ->
        unrecognized(source, line, column, tokens, errors)
    end
  end

  defp lex(<<char, _::binary>> = source, line, column, tokens, errors)
       when char in ?a..?z or char in ?A..?Z or char == ?_,
       do: word(source, line, column, tokens, errors)

  defp lex(<<char, rest::binary>>, line, column, tokens, errors)
       when is_map_key(@punctuation, char) do
    token = {Map.fetch!(@punctuation, char), nil, line, column}
    lex(rest, line, column + 1, [token | tokens], errors)
  end

  defp lex(source, line, column, tokens, errors),
    do: unrecognized(source, line, column, tokens, errors)

  defp line_comment(source, line, column, tokens, errors) do
    comment = take_while(source, &(&1 not in [?\r, ?\n]))
    rest = binary_part(source, byte_size(comment), byte_size(source) - byte_size(comment))
    lex(rest, line, column + String.length(comment), tokens, errors)
  end

  defp word(source, line, column, tokens, errors) do
    text = take_while(source, &word_char?/1)

    token =
      case text do
        "true" -> {:boolean, true}
        "false" -> {:boolean, false}
        "null" -> {:null, nil}
        "_" -> {:underscore, nil}
        name -> {:ident, name}
      end

    emit(source, byte_size(text), token, line, column, tokens, errors)
  end

  defp emit(source, length, {type, value}, line, column, tokens, errors) do
    text = binary_part(source, 0, length)
    rest = binary_part(source, length, byte_size(source) - length)
    {next_line, next_column} = advance(text, line, column)
    lex(rest, next_line, next_column, [{type, value, line, column} | tokens], errors)
  end

  defp unrecognized(source, line, column, tokens, errors) do
    <<char::utf8, rest::binary>> = valid_start(source)
    error = {line, column, "token recognition error at: '#{<<char::utf8>>}'", :lexer}
    {next_line, next_column} = advance(<<char::utf8>>, line, column)
    lex(rest, next_line, next_column, tokens, [error | errors])
  end

  # A byte that does not start a UTF-8 character is read as U+FFFD.
  defp valid_start(<<_char::utf8, _::binary>> = source), do: source
  defp valid_start(<<_byte, rest::binary>>), do: <<0xFFFD::utf8, rest::binary>>

  # The longest string literal at the start of `source`, as
  # {byte length, value}, or nil. Raw forms start with `r` or `R`.
  defp string_token(<<prefix, ?", ?", ?", rest::binary>>) when prefix in [?r, ?R] do
    # Unterminated, `r""` is still a raw string.
    case :binary.match(rest, ~s(""")) do
      {at, 3} -> {at + 7, binary_part(rest, 0, at)}
      :nomatch -> {3, ""}
    end
  end

  defp string_token(<<prefix, ?", rest::binary>>) when prefix in [?r, ?R], do: raw_string(rest)

  defp string_token(<<?", ?", ?", rest::binary>> = source) do
    case scan_escaped(rest, 0, ~s(""")) do
      {:ok, at} -> {at + 6, unescape(binary_part(rest, 0, at))}
      :error -> standard_string(source)
    end
  end

  defp string_token(<<?", _::binary>> = source), do: standard_string(source)
  defp string_token(_source), do: nil

  # `r"` followed by anything but a quote or line break, up to a quote.
  defp raw_string(rest) do
    content = take_while(rest, &(&1 not in [?", ?\r, ?\n]))
    size = byte_size(content)

    case rest do
      <<_content::binary-size(^size), ?", _::binary>> -> {size + 3, content}
      _unterminated -> nil
    end
  end

  defp standard_string(<<?", rest::binary>>) do
    case scan_escaped(rest, 0, ~s(")) do
      {:ok, at} -> {at + 2, unescape(binary_part(rest, 0, at))}
      :error -> nil
    end
  end

  # The offset of the first `closer` in `rest` not taken by a backslash
  # escape.
  defp scan_escaped(rest, at, closer) do
    case rest do
      <<_skip::binary-size(^at), ^closer::binary, _::binary>> ->
        {:ok, at}

      <<_skip::binary-size(^at), ?\\, _escaped, _::binary>> ->
        scan_escaped(rest, at + 2, closer)

      <<_skip::binary-size(^at), _char, _::binary>> ->
        scan_escaped(rest, at + 1, closer)

      _end ->
        :error
    end
  end

  @doc """
  Resolves the escapes a standard or triple-quoted string supports:
  `\\n`, `\\r`, `\\t`, `\\\\` and `\\"`. Any other backslash stays as
  written.

      iex> A2UIAgent.Express.Syntax.unescape(~S(a\\nb\\d))
      "a\\nb\\\\d"
  """
  @spec unescape(String.t()) :: String.t()
  def unescape(text) do
    Regex.replace(~r/\\(.)/su, text, fn whole, char ->
      case char do
        "n" -> "\n"
        "r" -> "\r"
        "t" -> "\t"
        "\\" -> "\\"
        "\"" -> "\""
        _other -> whole
      end
    end)
  end

  defp number(text) do
    if String.contains?(text, "."),
      do: String.to_float(text),
      else: String.to_integer(text)
  end

  defp take_while(binary, fun), do: take_while(binary, fun, 0)

  defp take_while(binary, fun, at) do
    case binary do
      <<prefix::binary-size(^at), char, _::binary>> ->
        if fun.(char), do: take_while(binary, fun, at + 1), else: prefix

      _end ->
        binary
    end
  end

  defp word_char?(char),
    do: char in ?a..?z or char in ?A..?Z or char in ?0..?9 or char == ?_

  defp path_char?(char), do: word_char?(char) or char == ?/

  # The line and column after `text`, which starts at `line`:`column`.
  defp advance(text, line, column) do
    if String.contains?(text, ["\n", "\r"]) do
      lines = String.split(text, ~r/\r\n|\r|\n/)
      {line + length(lines) - 1, String.length(List.last(lines))}
    else
      {line, column + String.length(text)}
    end
  end

  # -- parser -------------------------------------------------------------------------

  # Statements with the line each starts on, and the first parser error.
  defp statements([{:eof, _, _, _}], acc), do: {Enum.reverse(acc), nil}

  defp statements([{_type, _value, line, _column} | _] = tokens, acc) do
    case parse_statement(tokens) do
      {:ok, statement, rest} -> statements(rest, [{statement, line} | acc])
      {:error, error} -> {Enum.reverse(acc), error}
    end
  end

  defp parse_statement(tokens) do
    {statement, rest} = statement(tokens)
    {:ok, statement, rest}
  catch
    {:syntax_error, line, column, message} -> {:error, {line, column, message, :parser}}
  end

  defp statement([{type, value, _, _}, {:eq, _, _, _} | rest]) when type in [:ident, :path] do
    target = if type == :path, do: "$" <> value, else: value
    {expression, rest} = expression(rest)
    {{:assign, target, expression}, rest}
  end

  defp statement(tokens) do
    {expression, rest} = expression(tokens)
    {{:expr, expression}, rest}
  end

  defp expression([{:lbracket, _, _, _} | rest]) do
    {items, rest} = sequence(rest, :rbracket, &expression/1)
    {items, rest}
  end

  defp expression([{:lbrace, _, _, _} | rest]) do
    {pairs, rest} = sequence(rest, :rbrace, &map_entry/1)
    {{:map, put_pairs(pairs)}, rest}
  end

  defp expression([{:path, path, _, _} | rest]), do: {{:path, path}, rest}

  defp expression([{:check, name, _, _}, {:lparen, _, _, _} | rest]) do
    {args, rest} = sequence(rest, :rparen, &expression/1)
    {{:check, name, args}, rest}
  end

  defp expression([{:check, name, _, _} | rest]), do: {{:check, name, []}, rest}

  defp expression([{:ident, name, _, _}, {:lparen, _, _, _} | rest]) do
    {args, rest} = sequence(rest, :rparen, &argument/1)

    {positional, keyword} =
      Enum.reduce(args, {[], []}, fn
        {:keyword, key, value}, {positional, keyword} -> {positional, [{key, value} | keyword]}
        {:positional, value}, {positional, keyword} -> {[value | positional], keyword}
      end)

    {{:call, name, Enum.reverse(positional), put_pairs(Enum.reverse(keyword))}, rest}
  end

  defp expression([{:ident, name, _, _} | rest]), do: {{:var, name}, rest}
  defp expression([{:underscore, _, _, _} | rest]), do: {:skipped, rest}

  defp expression([{type, value, _, _} | rest]) when type in [:string, :number, :boolean],
    do: {value, rest}

  defp expression([{:null, _, _, _} | rest]), do: {nil, rest}
  defp expression([token | _]), do: fail(token, "an expression")

  defp argument([{:ident, key, _, _}, {:eq, _, _, _} | rest]) do
    {value, rest} = expression(rest)
    {{:keyword, key, value}, rest}
  end

  defp argument(tokens) do
    {value, rest} = expression(tokens)
    {{:positional, value}, rest}
  end

  defp map_entry([{type, key, _, _}, {:colon, _, _, _} | rest]) when type in [:ident, :string] do
    {value, rest} = expression(rest)
    {{key, value}, rest}
  end

  defp map_entry([{type, _, _, _}, next | _]) when type in [:ident, :string],
    do: fail(next, "':'")

  defp map_entry([token | _]), do: fail(token, "a map key")

  # `(item (',' item)* ','?)? closer`, after the opening bracket.
  defp sequence([{closer, _, _, _} | rest], closer, _item), do: {[], rest}

  defp sequence(tokens, closer, item) do
    {first, rest} = item.(tokens)
    sequence_rest(rest, closer, item, [first])
  end

  defp sequence_rest([{closer, _, _, _} | rest], closer, _item, acc),
    do: {Enum.reverse(acc), rest}

  defp sequence_rest([{:comma, _, _, _}, {closer, _, _, _} | rest], closer, _item, acc),
    do: {Enum.reverse(acc), rest}

  defp sequence_rest([{:comma, _, _, _} | rest], closer, item, acc) do
    {next, rest} = item.(rest)
    sequence_rest(rest, closer, item, [next | acc])
  end

  defp sequence_rest([token | _], closer, _item, _acc),
    do: fail(token, "',' or '#{closer_text(closer)}'")

  defp closer_text(:rbracket), do: "]"
  defp closer_text(:rbrace), do: "}"
  defp closer_text(:rparen), do: ")"

  defp put_pairs(pairs) do
    Enum.reduce(pairs, [], fn {key, value}, acc ->
      if List.keymember?(acc, key, 0),
        do: List.keyreplace(acc, key, 0, {key, value}),
        else: acc ++ [{key, value}]
    end)
  end

  defp fail({type, value, line, column}, expected) do
    throw(
      {:syntax_error, line, column,
       "mismatched input #{describe(type, value)} expecting #{expected}"}
    )
  end

  defp describe(:eof, _value), do: "'<EOF>'"
  defp describe(:string, value), do: inspect(value)
  defp describe(:path, value), do: "'$#{value}'"
  defp describe(:check, value), do: "'?#{value}'"
  defp describe(type, nil), do: "'#{token_text(type)}'"
  defp describe(_type, value), do: "'#{value}'"

  defp token_text(:null), do: "null"
  defp token_text(:underscore), do: "_"

  defp token_text(type) do
    {char, ^type} = Enum.find(@punctuation, fn {_char, name} -> name == type end)
    <<char>>
  end
end

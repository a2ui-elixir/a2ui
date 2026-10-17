defmodule A2UICore.Schema.ECMA262 do
  @moduledoc """
  ECMA-262 → PCRE regex translation for the `pattern` and
  `patternProperties` keywords.

  JSON Schema defines `pattern` as an unanchored ECMA-262 regular
  expression with Unicode semantics. PCRE (Erlang's `:re`) differs in
  ways the translation covers:

  * **`$` anchor** — ECMA-262 `$` matches only at the end of the input
    when the pattern is not multiline; PCRE `$` also matches before a
    trailing newline. The reference implementation rewrites unescaped
    `$` outside character classes to an absolute end anchor; so does
    this module (`\\z`).
  * **Character classes** — `\\d`, `\\w` and `\\b` are ASCII, as in
    ECMA-262 (patterns compile without PCRE's Unicode classes); `\\s`
    is ECMA-262's white space and line terminators (PCRE's Unicode
    spaces plus U+FEFF), `\\v` the vertical tab alone, and `.` any
    character but a line terminator.
  * **Escapes** — `\\uXXXX` (a surrogate pair of them is one code
    point) and `\\u{X...}` become PCRE's `\\x{...}`.
  * **Unicode property names** — `\\p{...}` and `\\P{...}` take
    ECMA-262's names. PCRE knows the short General_Category values
    (`L`, `Lu`), scripts (`Script=Greek`, `scx=Grek`) and binary
    properties (`Alphabetic`, `XID_Start`), but not the long
    General_Category values (`Letter`, `Uppercase_Letter`), the
    `General_Category=`/`gc=` forms or `Assigned`; those are rewritten.
  * **XID properties on older PCRE** — Erlang/OTP 28 and later bundle
    PCRE2, whose `XID_Start` and `XID_Continue` are exact. Older PCRE
    lacks them, so there they expand to a Unicode-derived
    approximation: `XID_Start` ≈ `\\p{L}\\p{Nl}`, `XID_Continue` ≈
    `\\p{L}\\p{Nl}\\p{Mn}\\p{Mc}\\p{Nd}\\p{Pc}`.

  Matching is *search* (unanchored), per JSON Schema. A search stops
  after a million backtracking steps: patterns come from agents and
  catalogs, and one such as `^(a+)+$` would otherwise run until PCRE's
  own limit, ten times that, and then report no match.
  """

  alias A2UICore.Error

  @moduledoc since: "0.1.0"

  @match_limit 1_000_000

  @native_xid match?({:ok, _regex}, Regex.compile("\\p{XID_Start}", "u"))

  # ECMA-262 white space and line terminators: PCRE's spaces (Unicode
  # category Z, tab, line feed, vertical tab, form feed, carriage return)
  # and U+FEFF.
  @space "\\p{Xsp}\\x{FEFF}"

  # ECMA-262 General_Category values (canonical names and aliases) by the
  # PCRE name for the same category.
  @general_categories [
    {"C", ~w(C Other)},
    {"Cc", ~w(Cc Control cntrl)},
    {"Cf", ~w(Cf Format)},
    {"Cn", ~w(Cn Unassigned)},
    {"Co", ~w(Co Private_Use)},
    {"Cs", ~w(Cs Surrogate)},
    {"L", ~w(L Letter)},
    {"L&", ~w(LC Cased_Letter)},
    {"Ll", ~w(Ll Lowercase_Letter)},
    {"Lm", ~w(Lm Modifier_Letter)},
    {"Lo", ~w(Lo Other_Letter)},
    {"Lt", ~w(Lt Titlecase_Letter)},
    {"Lu", ~w(Lu Uppercase_Letter)},
    {"M", ~w(M Mark Combining_Mark)},
    {"Mc", ~w(Mc Spacing_Mark)},
    {"Me", ~w(Me Enclosing_Mark)},
    {"Mn", ~w(Mn Nonspacing_Mark)},
    {"N", ~w(N Number)},
    {"Nd", ~w(Nd Decimal_Number digit)},
    {"Nl", ~w(Nl Letter_Number)},
    {"No", ~w(No Other_Number)},
    {"P", ~w(P Punctuation punct)},
    {"Pc", ~w(Pc Connector_Punctuation)},
    {"Pd", ~w(Pd Dash_Punctuation)},
    {"Pe", ~w(Pe Close_Punctuation)},
    {"Pf", ~w(Pf Final_Punctuation)},
    {"Pi", ~w(Pi Initial_Punctuation)},
    {"Po", ~w(Po Other_Punctuation)},
    {"Ps", ~w(Ps Open_Punctuation)},
    {"S", ~w(S Symbol)},
    {"Sc", ~w(Sc Currency_Symbol)},
    {"Sk", ~w(Sk Modifier_Symbol)},
    {"Sm", ~w(Sm Math_Symbol)},
    {"So", ~w(So Other_Symbol)},
    {"Z", ~w(Z Separator)},
    {"Zl", ~w(Zl Line_Separator)},
    {"Zp", ~w(Zp Paragraph_Separator)},
    {"Zs", ~w(Zs Space_Separator)}
  ]

  # ECMA-262 property expressions PCRE spells differently; `{:not, name}`
  # is the complement of a PCRE property.
  @properties for {pcre, names} <- @general_categories,
                  name <- names,
                  form <- [name, "General_Category=" <> name, "gc=" <> name],
                  into: %{"Assigned" => {:not, "Cn"}},
                  do: {form, pcre}

  @doc """
  Compiles an ECMA-262 pattern into a PCRE `Regex` after translation.

  Returns `{:ok, regex}` or `{:error, %A2UICore.Error{}}`.
  """
  @spec compile(String.t()) :: {:ok, Regex.t()} | {:error, Error.t()}
  def compile(pattern) when is_binary(pattern) do
    translated = do_translate(pattern, false, "")

    case Regex.compile(translated, [:unicode]) do
      {:ok, regex} ->
        {:ok, regex}

      {:error, reason} ->
        {:error,
         Error.new(
           :expression,
           "INVALID_REGEX",
           "Cannot compile schema pattern #{inspect(pattern)}: #{inspect(reason)}"
         )}
    end
  end

  @doc """
  Like `compile/1`, but raises `A2UICore.Error` when the pattern does not
  compile.
  """
  @spec compile!(String.t()) :: Regex.t()
  def compile!(pattern) do
    case compile(pattern) do
      {:ok, regex} -> regex
      {:error, error} -> raise error
    end
  end

  @doc """
  Searches `value` for the ECMA-262 `pattern` (unanchored, per JSON
  Schema).

  Returns `{:ok, boolean}`, or `{:error, error}` when the pattern itself
  cannot compile (`INVALID_REGEX`) or the search takes more than a million
  backtracking steps (`REGEX_LIMIT`); the caller decides how to surface
  that.
  """
  @spec search(String.t(), String.t()) :: {:ok, boolean()} | {:error, Error.t()}
  def search(pattern, value) when is_binary(pattern) and is_binary(value) do
    with {:ok, regex} <- compile(pattern) do
      options = [:report_errors, capture: :none, match_limit: @match_limit]

      case :re.run(value, regex.re_pattern, options) do
        :match ->
          {:ok, true}

        :nomatch ->
          {:ok, false}

        {:error, reason} ->
          {:error,
           Error.new(
             :expression,
             "REGEX_LIMIT",
             "Searching with pattern #{inspect(pattern)} took too many steps: #{inspect(reason)}"
           )}
      end
    end
  end

  @doc """
  Like `search/2` but returns `false` on a pattern that fails to compile.
  """
  @spec match?(String.t(), String.t()) :: boolean()
  def match?(pattern, value) when is_binary(pattern) and is_binary(value) do
    case search(pattern, value) do
      {:ok, result} -> result
      {:error, _} -> false
    end
  end

  # -- scanner --------------------------------------------------------------
  # `in_class` tracks whether we are inside a `[...]` character class, so
  # that `$` stays literal there (and, on older PCRE, XID approximations
  # splice into the class).

  defp do_translate(<<>>, _in_class, acc), do: acc

  unless @native_xid do
    defp do_translate("\\p{XID_Start}" <> rest, in_class, acc) do
      emit = if in_class, do: "\\p{L}\\p{Nl}", else: "[\\p{L}\\p{Nl}]"
      do_translate(rest, in_class, acc <> emit)
    end

    defp do_translate("\\p{XID_Continue}" <> rest, in_class, acc) do
      emit =
        if in_class,
          do: "\\p{L}\\p{Nl}\\p{Mn}\\p{Mc}\\p{Nd}\\p{Pc}",
          else: "[\\p{L}\\p{Nl}\\p{Mn}\\p{Mc}\\p{Nd}\\p{Pc}]"

      do_translate(rest, in_class, acc <> emit)
    end
  end

  defp do_translate("\\s" <> rest, in_class, acc),
    do: do_translate(rest, in_class, acc <> if(in_class, do: @space, else: "[#{@space}]"))

  # Inside a class, the complement of U+FEFF and PCRE's spaces cannot be
  # spelled; it is approximated by the complement of PCRE's spaces.
  defp do_translate("\\S" <> rest, in_class, acc),
    do: do_translate(rest, in_class, acc <> if(in_class, do: "\\P{Xsp}", else: "[^#{@space}]"))

  defp do_translate("\\v" <> rest, in_class, acc),
    do: do_translate(rest, in_class, acc <> "\\x{0B}")

  defp do_translate("." <> rest, false, acc),
    do: do_translate(rest, false, acc <> "[^\\n\\r\\x{2028}\\x{2029}]")

  defp do_translate("\\u{" <> rest = input, in_class, acc) do
    with [digits, rest] <- String.split(rest, "}", parts: 2),
         {:ok, code_point} <- hex(digits) do
      do_translate(rest, in_class, acc <> code_point_escape(code_point))
    else
      _not_a_code_point -> escape_verbatim(input, in_class, acc)
    end
  end

  defp do_translate(<<"\\u", digits::binary-size(4), rest::binary>> = input, in_class, acc) do
    case hex(digits) do
      {:ok, high} when high in 0xD800..0xDBFF -> surrogate_pair(high, rest, in_class, acc)
      {:ok, unit} -> do_translate(rest, in_class, acc <> code_point_escape(unit))
      :error -> escape_verbatim(input, in_class, acc)
    end
  end

  defp do_translate(<<?\\, p, ?{, rest::binary>>, in_class, acc) when p in [?p, ?P] do
    case String.split(rest, "}", parts: 2) do
      [name, rest] -> do_translate(rest, in_class, acc <> property(p, name))
      [_unclosed] -> do_translate(rest, in_class, acc <> <<?\\, p, ?{>>)
    end
  end

  # Character class entry: `[` outside a class opens one. `[` inside a
  # class is a literal. Leading `]` right after `[` or `[^` is a literal
  # member (PCRE/ECMA rule), so those sequences keep the class open.
  defp do_translate("[^]" <> rest, false, acc),
    do: do_translate(rest, true, acc <> "[^]")

  defp do_translate("[]" <> rest, false, acc),
    do: do_translate(rest, true, acc <> "[]")

  defp do_translate("[" <> rest, false, acc),
    do: do_translate(rest, true, acc <> "[")

  # `]` closes an open class; a `]` with no open class is a literal.
  defp do_translate("]" <> rest, true, acc),
    do: do_translate(rest, false, acc <> "]")

  # `$` outside a class becomes the absolute anchor `\z`; inside a class
  # it stays literal and is handled by the catch-all clause.
  defp do_translate("$" <> rest, false, acc),
    do: do_translate(rest, false, acc <> "\\z")

  # Escaped character: pass through verbatim (keeps `\$`, `\\d`, `\\p{L}`
  # etc. intact). The XID clauses above run before this one.
  defp do_translate("\\" <> <<c::utf8, rest::binary>>, in_class, acc),
    do: do_translate(rest, in_class, acc <> "\\" <> <<c::utf8>>)

  defp do_translate(<<c::utf8, rest::binary>>, in_class, acc),
    do: do_translate(rest, in_class, acc <> <<c::utf8>>)

  defp escape_verbatim("\\" <> <<c::utf8, rest::binary>>, in_class, acc),
    do: do_translate(rest, in_class, acc <> "\\" <> <<c::utf8>>)

  defp surrogate_pair(
         high,
         <<"\\u", digits::binary-size(4), rest::binary>> = input,
         in_class,
         acc
       ) do
    case hex(digits) do
      {:ok, low} when low in 0xDC00..0xDFFF ->
        code_point = 0x10000 + (high - 0xD800) * 0x400 + (low - 0xDC00)
        do_translate(rest, in_class, acc <> code_point_escape(code_point))

      _not_low ->
        do_translate(input, in_class, acc <> code_point_escape(high))
    end
  end

  defp surrogate_pair(high, rest, in_class, acc),
    do: do_translate(rest, in_class, acc <> code_point_escape(high))

  defp hex(digits) do
    if digits != "" and byte_size(digits) <= 6 and
         String.match?(digits, ~r/\A[0-9A-Fa-f]+\z/) do
      {:ok, String.to_integer(digits, 16)}
    else
      :error
    end
  end

  defp code_point_escape(code_point), do: "\\x{" <> Integer.to_string(code_point, 16) <> "}"

  defp property(p, name) do
    case Map.get(@properties, name, name) do
      {:not, pcre} -> <<?\\, negate(p), ?{, pcre::binary, ?}>>
      pcre -> <<?\\, p, ?{, pcre::binary, ?}>>
    end
  end

  defp negate(?p), do: ?P
  defp negate(?P), do: ?p
end

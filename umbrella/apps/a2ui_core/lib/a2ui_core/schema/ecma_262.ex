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
    ECMA-262, and are spelled out as ASCII classes: the PCRE of
    Erlang/OTP 27 and earlier counts Latin-1 letters such as `é` as word
    characters. `\\s` is ECMA-262's white space and line terminators
    (PCRE's Unicode spaces plus U+FEFF), `\\v` the vertical tab alone,
    and `.` any character but a line terminator.
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
    lacks them, so there they expand to their derivation: `XID_Start` ≈
    `\\p{L}\\p{Nl}` and the Other_ID_Start characters that stay
    identifiers under NFKC (`℘`, `℮`, U+1885, U+1886); `XID_Continue` ≈
    that, `\\p{Mn}\\p{Mc}\\p{Nd}\\p{Pc}` and the Other_ID_Continue
    characters (`·`, U+0387, U+1369 to U+1371, U+19DA).
  * **Scripts on older PCRE** — older PCRE names a script bare
    (`\\p{Greek}`), so `Script=` and `sc=` are dropped there, and
    `Script_Extensions=`/`scx=` fall back to the script. Only full script
    names (`Greek`, not `Grek`) are known to it.

  Matching is *search* (unanchored), per JSON Schema. A search stops
  after a million backtracking steps: patterns come from agents and
  catalogs, and one such as `^(a+)+$` would otherwise run until PCRE's
  own limit, ten times that, and then report no match.
  """

  alias A2UICore.Error

  @moduledoc since: "0.1.0"

  @match_limit 1_000_000

  @native_xid match?({:ok, _regex}, Regex.compile("\\p{XID_Start}", "u"))
  @native_scripts match?({:ok, _regex}, Regex.compile("\\p{sc=Greek}", "u"))

  # ECMA-262's ASCII word characters and digits, and their complements as
  # members of a class (surrogates left out).
  @word "A-Za-z0-9_"
  @not_word "\\x{0}-\\x{2F}\\x{3A}-\\x{40}\\x{5B}-\\x{5E}\\x{60}\\x{7B}-\\x{D7FF}\\x{E000}-\\x{10FFFF}"
  @not_digit "\\x{0}-\\x{2F}\\x{3A}-\\x{D7FF}\\x{E000}-\\x{10FFFF}"

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
    @id_start "\\p{L}\\p{Nl}\\x{1885}\\x{1886}\\x{2118}\\x{212E}"
    @id_continue @id_start <>
                   "\\p{Mn}\\p{Mc}\\p{Nd}\\p{Pc}\\x{B7}\\x{387}\\x{1369}-\\x{1371}\\x{19DA}"

    defp do_translate("\\p{XID_Start}" <> rest, in_class, acc),
      do: do_translate(rest, in_class, acc <> members(@id_start, in_class))

    defp do_translate("\\p{XID_Continue}" <> rest, in_class, acc),
      do: do_translate(rest, in_class, acc <> members(@id_continue, in_class))
  end

  defp do_translate("\\d" <> rest, in_class, acc),
    do: do_translate(rest, in_class, acc <> members("0-9", in_class))

  defp do_translate("\\D" <> rest, in_class, acc),
    do: do_translate(rest, in_class, acc <> if(in_class, do: @not_digit, else: "[^0-9]"))

  defp do_translate("\\w" <> rest, in_class, acc),
    do: do_translate(rest, in_class, acc <> members(@word, in_class))

  defp do_translate("\\W" <> rest, in_class, acc),
    do: do_translate(rest, in_class, acc <> if(in_class, do: @not_word, else: "[^#{@word}]"))

  # Inside a class `\\b` is a backspace, as in ECMA-262.
  defp do_translate("\\b" <> rest, true, acc), do: do_translate(rest, true, acc <> "\\x{08}")

  defp do_translate("\\b" <> rest, false, acc),
    do:
      do_translate(
        rest,
        false,
        acc <> "(?:(?<=[#{@word}])(?![#{@word}])|(?<![#{@word}])(?=[#{@word}]))"
      )

  defp do_translate("\\B" <> rest, false, acc),
    do:
      do_translate(
        rest,
        false,
        acc <> "(?:(?<=[#{@word}])(?=[#{@word}])|(?<![#{@word}])(?![#{@word}]))"
      )

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

  defp members(set, true), do: set
  defp members(set, false), do: "[" <> set <> "]"

  defp property(p, name) do
    case Map.get(@properties, name, script_name(name)) do
      {:not, pcre} -> <<?\\, negate(p), ?{, pcre::binary, ?}>>
      pcre -> <<?\\, p, ?{, pcre::binary, ?}>>
    end
  end

  if @native_scripts do
    defp script_name(name), do: name
  else
    defp script_name(name) do
      case String.split(name, "=", parts: 2) do
        [key, script] when key in ~w(Script sc Script_Extensions scx) -> script
        _other -> name
      end
    end
  end

  defp negate(?p), do: ?P
  defp negate(?P), do: ?p
end

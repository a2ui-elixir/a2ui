defmodule A2UICore.Schema.ECMA262 do
  @moduledoc """
  ECMA-262 → PCRE regex translation for the `pattern` and
  `patternProperties` keywords.

  JSON Schema semantics define `pattern` as an unanchored ECMA-262
  regular expression. PCRE (Erlang's `:re`) differs in two ways that
  matter for A2UI schemas:

  * **`$` anchor** — ECMA-262 `$` matches at end of input or before a
    final line terminator when the pattern is not multiline; PCRE `$`
    matches before a trailing newline even in single-line mode. The
    reference implementation rewrites unescaped `$` outside character
    classes to `\\z` (absolute end); we do the same.
  * **Unicode XID properties** — `\\p{XID_Start}` and `\\p{XID_Continue}`
    are not available in PCRE. We expand them to the same documented
    UAX #31 approximation used by `A2UICore.Identifier`:
      * `XID_Start` ≈ `\\p{L}\\p{Nl}`
      * `XID_Continue` ≈ `\\p{L}\\p{Nl}\\p{Mn}\\p{Mc}\\p{Nd}\\p{Pc}`

  Matching is *search* (unanchored), per JSON Schema.
  """

  alias A2UICore.Error

  @moduledoc since: "0.1.0"

  @doc """
  Compiles an ECMA-262 pattern into a PCRE `Regex` after translation.

  Returns `{:ok, regex}` or `{:error, %A2UICore.Error{}}`.
  """
  @spec compile(String.t()) :: {:ok, Regex.t()} | {:error, Error.t()}
  def compile(pattern) when is_binary(pattern) do
    translated = do_translate(pattern, false, "")

    case Regex.compile(translated, "u") do
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
  Searches `value` for the ECMA-262 `pattern` (unanchored, per JSON
  Schema).

  Returns `{:ok, boolean}` or `{:error, error}` when the pattern itself
  cannot compile (the caller decides how to surface that).
  """
  @spec search(String.t(), String.t()) :: {:ok, boolean()} | {:error, Error.t()}
  def search(pattern, value) when is_binary(pattern) and is_binary(value) do
    case compile(pattern) do
      {:ok, regex} -> {:ok, Regex.match?(regex, value)}
      {:error, _} = error -> error
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
  # that `$` stays literal there and XID properties splice into the class.

  defp do_translate(<<>>, _in_class, acc), do: acc

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
end

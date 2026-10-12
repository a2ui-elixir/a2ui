defmodule A2UICore.Identifier do
  @moduledoc """
  UAX #31 identifier validation for catalog entity names.

  Exact upstream regex: `^[\\p{XID_Start}_][\\p{XID_Continue}]*$`.

  PCRE2 (Erlang/OTP 29) has no `\\p{XID_Start}`/`\\p{XID_Continue}`
  support, so this module uses the Unicode-derived approximation
  `^[\\p{L}\\p{Nl}_][\\p{L}\\p{Nl}\\p{Mn}\\p{Mc}\\p{Nd}\\p{Pc}]*$`. This
  matches every conformance-relevant case from the reference suite:
  `Text`, `submit_form`, `_internal`, `Component_ℓ` pass;
  `1stItem`, `submit-form`, `user#name` fail.

  Two structural points follow the reference:

  * one optional leading `@` is stripped before testing;
  * the empty string is invalid.
  """

  alias A2UICore.Error

  @moduledoc since: "0.1.0"

  @pattern ~r/^[\p{L}\p{Nl}_][\p{L}\p{Nl}\p{Mn}\p{Mc}\p{Nd}\p{Pc}]*$/u

  @doc """
  Returns whether `name` is a valid UAX #31 identifier.
  """
  @spec valid?(term()) :: boolean()
  def valid?(name) when not is_binary(name), do: false
  def valid?(""), do: false

  def valid?(name) do
    stripped =
      case String.first(name) do
        "@" -> String.slice(name, 1..-1//1)
        _ -> name
      end

    stripped != "" and Regex.match?(@pattern, stripped)
  end

  @continue_pattern ~r/\A[\p{L}\p{Nl}\p{Mn}\p{Mc}\p{Nd}\p{Pc}]\z/u

  @doc """
  Returns whether `codepoint` (a one-character string) continues an
  identifier — the `XID_Continue` approximation used by `valid?/1`.
  Expression and path scanning use it to find token boundaries.

      iex> A2UICore.Identifier.continue?("a")
      true
      iex> A2UICore.Identifier.continue?("-")
      false
  """
  @spec continue?(term()) :: boolean()
  def continue?(<<c>>) when c in ?a..?z or c in ?A..?Z or c in ?0..?9 or c == ?_, do: true
  def continue?(<<c>>) when c < 128, do: false
  def continue?(char) when is_binary(char), do: Regex.match?(@continue_pattern, char)
  def continue?(_other), do: false

  @doc """
  Raises `A2UICore.Error` with category `:catalog` if `name` is not a
  valid UAX #31 identifier.
  """
  @spec assert_valid!(String.t(), String.t()) :: :ok
  def assert_valid!(name, context \\ "identifier") do
    if valid?(name) do
      :ok
    else
      Error.raise!(
        :catalog,
        "INVALID_IDENTIFIER",
        "Invalid UAX #31 #{context}: '#{name}'"
      )
    end
  end
end

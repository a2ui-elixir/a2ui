defmodule A2UICore.Identifier do
  @moduledoc """
  UAX #31 identifier validation for catalog entity names, with the
  upstream pattern `^[\\p{XID_Start}_][\\p{XID_Continue}]*$`, compiled
  like a schema pattern by `A2UICore.Schema.ECMA262`: exact on
  Erlang/OTP 28 and later, an approximation on older PCRE.

  Two structural points follow the reference:

  * the empty string is invalid;
  * a leading `@` makes a name invalid, unless `allow_leading_at: true`
    (payload validation, where a call may name a system function such
    as `@index`): then one leading `@` is ignored. Catalog declarations
    never allow it.
  """

  alias A2UICore.Error
  alias A2UICore.Schema.ECMA262

  @moduledoc since: "0.1.0"

  @pattern ECMA262.compile!("^[\\p{XID_Start}_][\\p{XID_Continue}]*$")

  @doc """
  Returns whether `name` is a valid UAX #31 identifier.

  Options: `allow_leading_at: true` ignores one leading `@`.

      iex> A2UICore.Identifier.valid?("submit_form")
      true
      iex> A2UICore.Identifier.valid?("@index")
      false
      iex> A2UICore.Identifier.valid?("@index", allow_leading_at: true)
      true
  """
  @spec valid?(term(), keyword()) :: boolean()
  def valid?(name, options \\ [])
  def valid?(name, _options) when not is_binary(name), do: false
  def valid?("", _options), do: false

  def valid?(name, options) do
    stripped =
      case name do
        "@" <> rest -> if Keyword.get(options, :allow_leading_at, false), do: rest, else: name
        _other -> name
      end

    stripped != "" and Regex.match?(@pattern, stripped)
  end

  @continue_pattern ECMA262.compile!("^\\p{XID_Continue}$")

  @doc """
  Returns whether `codepoint` (a one-character string) continues an
  identifier (`XID_Continue`, as in `valid?/1`). Expression and path
  scanning use it to find token boundaries.

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

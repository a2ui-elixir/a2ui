defmodule A2UIConformance.PyStr do
  @moduledoc false

  # Python's `str()` of a JSON value. The reference harness compares a
  # resolved property with its expectation as `str(actual) == str(expected)`,
  # so `"1"` and `1` are equal at the top level while `["1"]` and `[1]` are
  # not. Dict keys are printed sorted: Elixir maps carry no insertion
  # order, and both sides come from the same document order.

  @doc """
  `str(value)`: strings are printed bare, everything else as `repr`.
  """
  @spec str(term()) :: String.t()
  def str(value) when is_binary(value), do: value
  def str(value), do: repr(value)

  @doc """
  `repr(value)` of a JSON value.
  """
  @spec repr(term()) :: String.t()
  def repr(nil), do: "None"
  def repr(true), do: "True"
  def repr(false), do: "False"
  def repr(value) when is_integer(value), do: Integer.to_string(value)
  def repr(value) when is_float(value), do: float(value)
  def repr(value) when is_binary(value), do: string(value)

  def repr(value) when is_list(value),
    do: "[" <> Enum.map_join(value, ", ", &repr/1) <> "]"

  def repr(value) when is_map(value) do
    pairs =
      value
      |> Enum.sort_by(fn {key, _value} -> to_string(key) end)
      |> Enum.map_join(", ", fn {key, item} -> repr(to_string(key)) <> ": " <> repr(item) end)

    "{" <> pairs <> "}"
  end

  def repr(value), do: inspect(value)

  # Single quotes unless the text holds a single quote and no double quote.
  defp string(value) do
    quote_char =
      if String.contains?(value, "'") and not String.contains?(value, "\""), do: "\"", else: "'"

    body =
      value
      |> String.to_charlist()
      |> Enum.map_join(&escape(&1, quote_char))

    quote_char <> body <> quote_char
  end

  defp escape(?\\, _quote), do: "\\\\"
  defp escape(?\n, _quote), do: "\\n"
  defp escape(?\r, _quote), do: "\\r"
  defp escape(?\t, _quote), do: "\\t"
  defp escape(char, quote) when <<char::utf8>> == quote, do: "\\" <> quote
  defp escape(char, _quote) when char < 0x20 or char == 0x7F, do: "\\x" <> hex(char, 2)
  defp escape(char, _quote), do: <<char::utf8>>

  defp hex(value, width),
    do: value |> Integer.to_string(16) |> String.downcase() |> String.pad_leading(width, "0")

  # `repr(float)`: the shortest round-trip digits, fixed notation for
  # exponents in [-4, 16), scientific (`1e+16`, `1.5e-07`) otherwise.
  defp float(value) do
    {sign, digits, exponent} = decompose(value)

    body =
      cond do
        digits == "0" -> "0.0"
        exponent < -4 or exponent >= 16 -> scientific(digits, exponent)
        true -> fixed(digits, exponent)
      end

    sign <> body
  end

  defp decompose(value) do
    text = Float.to_string(abs(value))
    sign = if match?(<<1::1, _rest::bitstring>>, <<value::float>>), do: "-", else: ""

    {mantissa, exponent} =
      case String.split(text, "e") do
        [mantissa, exponent] -> {mantissa, String.to_integer(exponent)}
        [mantissa] -> {mantissa, 0}
      end

    [whole, fraction] = String.split(mantissa, ".")
    digits = String.trim_leading(whole <> fraction, "0")
    leading_zeros = String.length(whole <> fraction) - String.length(digits)
    point = String.length(whole) - leading_zeros + exponent

    case String.trim_trailing(digits, "0") do
      "" -> {sign, "0", 0}
      trimmed -> {sign, trimmed, point - 1}
    end
  end

  defp fixed(digits, exponent) when exponent >= 0 do
    whole_length = exponent + 1
    padded = String.pad_trailing(digits, whole_length, "0")
    {whole, fraction} = String.split_at(padded, whole_length)
    whole <> "." <> if(fraction == "", do: "0", else: fraction)
  end

  defp fixed(digits, exponent),
    do: "0." <> String.duplicate("0", -exponent - 1) <> digits

  defp scientific(digits, exponent) do
    {first, rest} = String.split_at(digits, 1)
    mantissa = if rest == "", do: first, else: first <> "." <> rest
    sign = if exponent < 0, do: "-", else: "+"
    mantissa <> "e" <> sign <> String.pad_leading(Integer.to_string(abs(exponent)), 2, "0")
  end
end

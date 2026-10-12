defmodule A2UICore.Coerce do
  @moduledoc """
  Value coercions shared by the catalog functions: truthiness, text and
  number conversion.

  The rules follow the reference engines so that a function evaluates to
  the same result everywhere:

    * `truthy?/1` is Python's `bool()`: `nil`, `false`, `0`, `0.0`, `""`,
      `[]` and `%{}` are falsy, everything else is truthy.
    * `to_string/1` renders a value the way `formatString` interpolates it:
      `nil` is empty, booleans are `true`/`false`, objects and arrays are
      compact JSON, numbers use the shortest round-trip form.
    * `to_float/1` and `to_integer/1` accept numbers, booleans and numeric
      strings. The BEAM has no infinity or NaN, so `"inf"` and `"nan"`
      are not numbers here.

      iex> A2UICore.Coerce.truthy?(%{})
      false
      iex> A2UICore.Coerce.to_string([1, "a"])
      "[1,\\"a\\"]"
      iex> A2UICore.Coerce.to_float(" 42.5 ")
      {:ok, 42.5}
  """

  @moduledoc since: "0.1.0"

  @float_literal ~r/\A[+-]?(?:[0-9]+\.?[0-9]*|\.[0-9]+)(?:[eE][+-]?[0-9]+)?\z/
  @integer_literal ~r/\A[+-]?[0-9]+\z/

  @doc """
  Python truthiness of a decoded JSON value.
  """
  @spec truthy?(term()) :: boolean()
  def truthy?(nil), do: false
  def truthy?(false), do: false
  def truthy?(0), do: false
  def truthy?(value) when is_float(value), do: value != 0.0
  def truthy?(""), do: false
  def truthy?([]), do: false
  def truthy?(value) when is_map(value), do: map_size(value) > 0
  def truthy?(_value), do: true

  @doc """
  Renders a value as interpolated text.
  """
  @spec to_string(term()) :: String.t()
  def to_string(nil), do: ""
  def to_string(true), do: "true"
  def to_string(false), do: "false"
  def to_string(value) when is_binary(value), do: value
  def to_string(value) when is_integer(value), do: Integer.to_string(value)
  def to_string(value) when is_float(value), do: float_to_string(value)
  def to_string(value) when is_map(value) or is_list(value), do: Jason.encode!(value)
  def to_string(value), do: inspect(value)

  @doc """
  Python's `repr` of a float: the shortest round-trip digits, `1e+16`
  style exponents from `1e16`, and plain notation down to `1e-4`.
  """
  @spec float_to_string(float()) :: String.t()
  def float_to_string(value) when is_float(value) do
    {sign, coefficient, exponent} = decompose(value)
    digits = Integer.to_string(coefficient)
    # Position of the decimal point relative to the start of `digits`.
    point = String.length(digits) + exponent

    body =
      cond do
        point > 16 or point < -3 ->
          scientific(digits, point)

        point <= 0 ->
          "0." <> String.duplicate("0", -point) <> digits

        point >= String.length(digits) ->
          digits <> String.duplicate("0", point - String.length(digits)) <> ".0"

        true ->
          String.slice(digits, 0, point) <> "." <> String.slice(digits, point..-1//1)
      end

    sign <> body
  end

  defp scientific(digits, point) do
    exponent = point - 1
    mantissa = String.slice(digits, 0, 1)
    rest = String.slice(digits, 1..-1//1)
    mantissa = if rest == "", do: mantissa, else: mantissa <> "." <> rest

    exponent_text =
      if(exponent < 0, do: "-", else: "+") <>
        (exponent |> abs() |> Integer.to_string() |> String.pad_leading(2, "0"))

    mantissa <> "e" <> exponent_text
  end

  @doc """
  Splits a float into `{sign, coefficient, exponent}` with
  `value = ±coefficient × 10^exponent` using its shortest round-trip
  decimal representation. `sign` is `"-"` or `""` (negative zero keeps
  its sign).
  """
  @spec decompose(float()) :: {String.t(), non_neg_integer(), integer()}
  def decompose(value) when is_float(value) do
    text = :erlang.float_to_binary(value, [:short])
    {sign, unsigned} = split_sign(text)
    {mantissa, exponent} = split_exponent(unsigned)

    {integer_part, fraction_part} =
      case String.split(mantissa, ".", parts: 2) do
        [whole, fraction] -> {whole, fraction}
        [whole] -> {whole, ""}
      end

    coefficient = String.to_integer(integer_part <> fraction_part)
    normalize(sign, coefficient, exponent - String.length(fraction_part))
  end

  defp normalize(sign, 0, _exponent), do: {sign, 0, 0}

  defp normalize(sign, coefficient, exponent) when rem(coefficient, 10) == 0,
    do: normalize(sign, div(coefficient, 10), exponent + 1)

  defp normalize(sign, coefficient, exponent), do: {sign, coefficient, exponent}

  defp split_sign("-" <> rest), do: {"-", rest}
  defp split_sign(text), do: {"", text}

  defp split_exponent(text) do
    case String.split(text, ["e", "E"], parts: 2) do
      [mantissa, exponent] -> {mantissa, String.to_integer(exponent)}
      [mantissa] -> {mantissa, 0}
    end
  end

  @doc """
  Converts a value to a float, as Python's `float()` does.

  Returns `:error` for `nil`, containers and non-numeric strings.
  """
  @spec to_float(term()) :: {:ok, float()} | :error
  def to_float(value) when is_float(value), do: {:ok, value}
  def to_float(value) when is_integer(value), do: {:ok, value * 1.0}
  def to_float(true), do: {:ok, 1.0}
  def to_float(false), do: {:ok, 0.0}

  def to_float(value) when is_binary(value) do
    text = String.trim(value)

    if Regex.match?(@float_literal, text) do
      {:ok, parse_float(text)}
    else
      :error
    end
  end

  def to_float(_value), do: :error

  defp parse_float(text) do
    {sign, unsigned} = split_sign(String.trim_leading(text, "+"))
    {mantissa, exponent} = split_exponent(unsigned)

    {whole, fraction} =
      case String.split(mantissa, ".", parts: 2) do
        [whole, fraction] -> {whole, fraction}
        [whole] -> {whole, ""}
      end

    whole = if whole == "", do: "0", else: whole
    fraction = if fraction == "", do: "0", else: fraction
    exponent_part = if exponent == 0, do: "", else: "e#{exponent}"

    case Float.parse(sign <> whole <> "." <> fraction <> exponent_part) do
      {float, ""} -> float
      _overflow -> 0.0
    end
  end

  @doc """
  Converts a value to an integer, as Python's `int()` does: floats
  truncate toward zero, booleans are 0/1, strings must be integer
  literals.
  """
  @spec to_integer(term()) :: {:ok, integer()} | :error
  def to_integer(value) when is_integer(value), do: {:ok, value}
  def to_integer(value) when is_float(value), do: {:ok, trunc(value)}
  def to_integer(true), do: {:ok, 1}
  def to_integer(false), do: {:ok, 0}

  def to_integer(value) when is_binary(value) do
    text = String.trim(value)

    if Regex.match?(@integer_literal, text) do
      {:ok, text |> String.trim_leading("+") |> String.to_integer()}
    else
      :error
    end
  end

  def to_integer(_value), do: :error
end

defmodule A2UICore.Formatter.Default do
  @moduledoc """
  The built-in `A2UICore.Formatter`: `en-US` conventions for every locale.

  Numbers follow CLDR's `#,##0.###` decimal pattern and `¤#,##0.00`
  currency pattern with round-half-even on the shortest decimal form of
  the input (so `2.675` rounds to `2.68`, as the reference's decimal
  arithmetic does). Alphabetic currency symbols are separated from the
  digits by U+00A0 (`CHF 1,234.56`), CLDR's `currencySpacing`.

      iex> A2UICore.Formatter.Default.decimal(1234.567, decimals: 2)
      "1,234.57"
      iex> A2UICore.Formatter.Default.currency(99.99, "USD", [])
      "$99.99"
      iex> A2UICore.Formatter.Default.date(~U[2026-08-26 12:00:00Z], "MMM d, yyyy", [])
      "Aug 26, 2026"

  Date patterns are Unicode TR35 patterns: text in single quotes is
  literal and `''` is a quote.

      iex> A2UICore.Formatter.Default.date(~U[2026-08-26 19:30:00Z], "EEEE 'at' h:mm a", [])
      "Wednesday at 7:30 PM"
  """

  @behaviour A2UICore.Formatter

  alias A2UICore.Coerce

  @moduledoc since: "0.1.0"

  @months ~w(January February March April May June July August September October November December)
  @weekdays ~w(Monday Tuesday Wednesday Thursday Friday Saturday Sunday)

  @currency_symbols %{
    "USD" => "$",
    "EUR" => "€",
    "GBP" => "£",
    "JPY" => "¥",
    "INR" => "₹",
    "CAD" => "CA$",
    "AUD" => "A$",
    "CNY" => "CN¥",
    "KRW" => "₩",
    "MXN" => "MX$",
    "NZD" => "NZ$",
    "BRL" => "R$",
    "ILS" => "₪",
    "VND" => "₫",
    "HKD" => "HK$",
    "TWD" => "NT$",
    "PHP" => "₱",
    "XCD" => "EC$",
    "XAF" => "FCFA",
    "XOF" => "F CFA",
    "XPF" => "CFPF"
  }

  @nbsp "\u00A0"
  @date_tokens ~r/yyyy|yy|MMMM|MMM|MM|M|EEEE|E|dd|d|HH|H|hh|h|mm|ss|a|%/

  @impl true
  def decimal(value, opts) when is_number(value) do
    grouping = Keyword.get(opts, :grouping, true)

    case Keyword.get(opts, :decimals) do
      nil -> render(value, 0, 3, grouping)
      decimals -> render(value, decimals, decimals, grouping)
    end
  end

  @impl true
  def currency(value, currency, opts) when is_number(value) and is_binary(currency) do
    decimals = Keyword.get(opts, :decimals, 2)
    grouping = Keyword.get(opts, :grouping, true)
    symbol = Map.get(@currency_symbols, currency, currency)
    {sign, number} = render_parts(value, decimals, decimals, grouping)

    sign <> symbol <> spacing(symbol) <> number
  end

  @impl true
  def date(
        %{year: year, month: month, day: day, hour: hour, minute: minute, second: second},
        format,
        _opts
      )
      when is_binary(format) do
    parts = %{
      year: year,
      month: month,
      day: day,
      hour: hour,
      minute: minute,
      second: second,
      weekday: Date.day_of_week(Date.new!(year, month, day)) - 1
    }

    format
    |> pattern_segments([])
    |> Enum.map_join(fn
      {:literal, text} -> text
      {:pattern, text} -> Regex.replace(@date_tokens, text, &date_token(&1, parts))
    end)
  end

  @impl true
  def plural(value, _opts) when is_number(value) do
    if abs(value) == 1, do: "one", else: "other"
  end

  # -- dates -----------------------------------------------------------------

  # TR35 quoting: text between single quotes is literal, and two single
  # quotes are one quote, inside quoted text or out. An unclosed quote
  # runs to the end.
  defp pattern_segments("", acc), do: Enum.reverse(acc)
  defp pattern_segments("''" <> rest, acc), do: pattern_segments(rest, [{:literal, "'"} | acc])

  defp pattern_segments("'" <> rest, acc) do
    {text, rest} = quoted(rest, "")
    pattern_segments(rest, [{:literal, text} | acc])
  end

  defp pattern_segments(format, acc) do
    case :binary.match(format, "'") do
      {at, _length} ->
        pattern_segments(binary_part(format, at, byte_size(format) - at), [
          {:pattern, binary_part(format, 0, at)} | acc
        ])

      :nomatch ->
        Enum.reverse([{:pattern, format} | acc])
    end
  end

  defp quoted("", text), do: {text, ""}
  defp quoted("''" <> rest, text), do: quoted(rest, text <> "'")
  defp quoted("'" <> rest, text), do: {text, rest}

  defp quoted(<<char::utf8, rest::binary>>, text), do: quoted(rest, text <> <<char::utf8>>)

  defp date_token("yyyy", parts), do: Integer.to_string(parts.year)
  defp date_token("yy", parts), do: parts.year |> Integer.to_string() |> String.slice(-2, 2)
  defp date_token("MMMM", parts), do: Enum.at(@months, parts.month - 1)
  defp date_token("MMM", parts), do: @months |> Enum.at(parts.month - 1) |> String.slice(0, 3)
  defp date_token("MM", parts), do: pad(parts.month)
  defp date_token("M", parts), do: Integer.to_string(parts.month)
  defp date_token("EEEE", parts), do: Enum.at(@weekdays, parts.weekday)
  defp date_token("E", parts), do: @weekdays |> Enum.at(parts.weekday) |> String.slice(0, 3)
  defp date_token("dd", parts), do: pad(parts.day)
  defp date_token("d", parts), do: Integer.to_string(parts.day)
  defp date_token("HH", parts), do: pad(parts.hour)
  defp date_token("H", parts), do: Integer.to_string(parts.hour)
  defp date_token("hh", parts), do: parts.hour |> twelve() |> pad()
  defp date_token("h", parts), do: parts.hour |> twelve() |> Integer.to_string()
  defp date_token("mm", parts), do: pad(parts.minute)
  defp date_token("ss", parts), do: pad(parts.second)
  defp date_token("a", parts), do: if(parts.hour < 12, do: "AM", else: "PM")
  defp date_token(token, _parts), do: token

  defp twelve(hour) do
    case rem(hour, 12) do
      0 -> 12
      hour -> hour
    end
  end

  defp pad(number), do: number |> Integer.to_string() |> String.pad_leading(2, "0")

  # -- numbers ---------------------------------------------------------------

  defp render(value, min_fraction, max_fraction, grouping) do
    {sign, number} = render_parts(value, min_fraction, max_fraction, grouping)
    sign <> number
  end

  defp render_parts(value, min_fraction, max_fraction, grouping) do
    {sign, coefficient, exponent} = decimal_parts(value)
    scaled = scale(coefficient, -exponent, max_fraction)

    digits =
      scaled
      |> Integer.to_string()
      |> String.pad_leading(max_fraction + 1, "0")

    integer_digits = String.slice(digits, 0, String.length(digits) - max_fraction)
    fraction_digits = String.slice(digits, String.length(digits) - max_fraction, max_fraction)
    fraction = trim_fraction(fraction_digits, min_fraction)
    integer = if grouping, do: group(integer_digits), else: integer_digits

    {sign, if(fraction == "", do: integer, else: integer <> "." <> fraction)}
  end

  defp decimal_parts(value) when is_integer(value),
    do: {if(value < 0, do: "-", else: ""), abs(value), 0}

  defp decimal_parts(value) when is_float(value), do: Coerce.decompose(value)

  # Scales `coefficient × 10^-places` to an integer with `target` fraction
  # digits, rounding half to even.
  defp scale(coefficient, places, target) when places <= target,
    do: coefficient * Integer.pow(10, target - places)

  defp scale(coefficient, places, target) do
    divisor = Integer.pow(10, places - target)
    quotient = div(coefficient, divisor)
    remainder = rem(coefficient, divisor)
    half = div(divisor, 2)

    cond do
      remainder > half -> quotient + 1
      remainder < half -> quotient
      rem(quotient, 2) == 0 -> quotient
      true -> quotient + 1
    end
  end

  defp trim_fraction(fraction, min_fraction) do
    extra = String.length(fraction) - min_fraction

    if extra > 0 do
      kept = fraction |> String.slice(min_fraction, extra) |> String.trim_trailing("0")
      String.slice(fraction, 0, min_fraction) <> kept
    else
      fraction
    end
  end

  defp group(digits) do
    digits
    |> String.reverse()
    |> String.graphemes()
    |> Enum.chunk_every(3)
    |> Enum.map_join(",", &Enum.join/1)
    |> String.reverse()
  end

  # CLDR currencySpacing: a symbol whose edge is not a symbol character
  # (a letter, as in `CHF`) is separated from the digits.
  defp spacing(symbol) do
    if Regex.match?(~r/\A\p{S}/u, String.last(symbol)), do: "", else: @nbsp
  end
end

defmodule A2UICore.Schema.Format do
  @moduledoc false

  # Assertion semantics for the JSON Schema `format` values the A2UI
  # schemas and catalogs use, matching ajv-formats' "full" mode (what the
  # upstream spec test runner loads):
  #
  #   * `date`      — RFC 3339 full-date with a real calendar day,
  #   * `time`      — RFC 3339 full-time; the time zone is required, and a
  #                   leap second is accepted only at 23:59 UTC,
  #   * `date-time` — date and time joined by `T`, `t` or a space,
  #   * `uri`       — an absolute RFC 3986 URI (scheme required).
  #
  # Any other format is unknown and accepted, as in both ajv and
  # jsonschema.

  @date ~r/\A(\d\d\d\d)-(\d\d)-(\d\d)\z/
  @time ~r/\A(\d\d):(\d\d):(\d\d(?:\.\d+)?)(z|([+-])(\d\d)(?::?(\d\d))?)?\z/i
  @days_in_month {31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31}

  # RFC 3986 absolute URI: scheme ":" followed only by characters a URI may
  # contain, with `%` always introducing a two-digit hex escape.
  @uri ~r/\A[a-z][a-z0-9+\-.]*:(?:[a-z0-9\-._~!$&'()*+,;=:@\/?#\[\]]|%[0-9a-f]{2})*\z/i

  @doc false
  @spec valid?(String.t(), String.t()) :: boolean()
  def valid?("date", value), do: date?(value)
  def valid?("time", value), do: time?(value)
  def valid?("date-time", value), do: date_time?(value)
  def valid?("uri", value), do: uri?(value)
  def valid?(_unknown, _value), do: true

  defp date?(value) do
    case Regex.run(@date, value, capture: :all_but_first) do
      [y, m, d] ->
        {year, month, day} = {String.to_integer(y), String.to_integer(m), String.to_integer(d)}
        month in 1..12 and day >= 1 and day <= days_in_month(year, month)

      nil ->
        false
    end
  end

  defp days_in_month(year, 2) do
    if rem(year, 4) == 0 and (rem(year, 100) != 0 or rem(year, 400) == 0), do: 29, else: 28
  end

  defp days_in_month(_year, month), do: elem(@days_in_month, month - 1)

  defp time?(value) do
    case Regex.run(@time, value) do
      [_ | groups] -> time_parts?(groups)
      nil -> false
    end
  end

  defp time_parts?([hr, min, sec | zone]) do
    {hr, min, sec} = {String.to_integer(hr), String.to_integer(min), seconds(sec)}

    case zone do
      [] ->
        false

      [_tz | offset] ->
        {sign, tz_h, tz_m} = offset_parts(offset)

        cond do
          tz_h > 23 or tz_m > 59 -> false
          hr <= 23 and min <= 59 and sec < 60 -> true
          true -> leap_second?(hr, min, sec, sign, tz_h, tz_m)
        end
    end
  end

  defp offset_parts([]), do: {1, 0, 0}
  defp offset_parts([sign, h]), do: {sign(sign), String.to_integer(h), 0}
  defp offset_parts([sign, h, m]), do: {sign(sign), String.to_integer(h), String.to_integer(m)}

  defp sign("-"), do: -1
  defp sign(_plus), do: 1

  defp seconds(sec) do
    {value, _rest} = Float.parse(sec)
    value
  end

  defp leap_second?(hr, min, sec, sign, tz_h, tz_m) do
    utc_min = min - tz_m * sign
    utc_hr = hr - tz_h * sign - if(utc_min < 0, do: 1, else: 0)
    utc_hr in [23, -1] and utc_min in [59, -1] and sec < 61
  end

  defp date_time?(value) do
    case String.split(value, ~r/[tT\s]/) do
      [date, time] -> date?(date) and time?(time)
      _ -> false
    end
  end

  defp uri?(value), do: Regex.match?(@uri, value)
end

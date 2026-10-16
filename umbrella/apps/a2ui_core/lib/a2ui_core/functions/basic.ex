defmodule A2UICore.Functions.Basic do
  @moduledoc """
  Implementations of the basic catalog's functions.

  `implementations/2` returns `%{name => execute}` for a protocol
  version; `A2UICore.Catalog.Basic` attaches them to the published
  catalog document. Each `execute` takes the resolved arguments and the
  `A2UICore.Resolution.DataContext` of the call and returns
  `{:ok, value}` or `{:error, %A2UICore.Error{category: :expression}}`.

  Version differences follow the reference:

    * v0.9 validators (`required`, `regex`, `length`, `numeric`,
      `email`) return booleans; v1.0 validators return a validation
      result `%{"valid" => boolean}` (`email` adds `code`, `message`,
      `severity` on failure);
    * v1.0 `and`/`or`/`not` treat a map with a boolean `"valid"` as
      true/false by validity; v0.9 treats it as an ordinary object;
    * v1.0 resolves `formatString` interpolations with `@path`/`@call`.

  Locale-sensitive formatting goes through `A2UICore.Formatter`
  (`:formatter` option, default `A2UICore.Formatter.Default`).
  """

  alias A2UICore.{Coerce, Error, Expression, SemVer}
  alias A2UICore.Formatter.Default
  alias A2UICore.Resolution.DataContext
  alias A2UICore.Schema.ECMA262

  @moduledoc since: "0.1.0"

  @allowed_url_schemes ["http", "https", "mailto", "tel"]
  @email ~r/^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$/
  @email_message "Please enter a valid email address (e.g. user@example.com)."

  @doc """
  The function implementations of the basic catalog of `version`.

  Options: `:formatter` — an `A2UICore.Formatter` module.
  """
  @spec implementations(String.t(), keyword()) :: %{
          optional(String.t()) => A2UICore.Catalog.Function.execute()
        }
  def implementations(version, options \\ []) do
    formatter = Keyword.get(options, :formatter, Default)
    v1? = SemVer.at_least(version, "v1.0")

    %{
      "required" => fn args, _ctx -> {:ok, validity(required?(args), v1?)} end,
      "regex" => fn args, _ctx -> regex(args, v1?) end,
      "length" => fn args, _ctx -> length_check(args, v1?) end,
      "numeric" => fn args, _ctx -> {:ok, validity(numeric?(args), v1?)} end,
      "email" => fn args, _ctx -> {:ok, email(args, v1?)} end,
      "formatString" => fn args, ctx -> format_string(args, ctx, v1?) end,
      "formatNumber" => fn args, ctx -> format_number(args, ctx, formatter) end,
      "formatCurrency" => fn args, ctx -> format_currency(args, ctx, formatter) end,
      "formatDate" => fn args, ctx -> format_date(args, ctx, formatter, v1?) end,
      "pluralize" => fn args, ctx -> pluralize(args, ctx, formatter) end,
      "openUrl" => fn args, _ctx -> open_url(args) end,
      "and" => fn args, _ctx -> logical(args, "AndFunction", &Enum.all?/2, v1?) end,
      "or" => fn args, _ctx -> logical(args, "OrFunction", &Enum.any?/2, v1?) end,
      "not" => fn args, _ctx -> {:ok, not truthy_or_valid?(Map.get(args, "value"), v1?)} end
    }
  end

  # -- validators ---------------------------------------------------------------

  defp validity(valid?, true), do: %{"valid" => valid?}
  defp validity(valid?, false), do: valid?

  defp required?(args) do
    value = Map.get(args, "value")
    value != nil and value != "" and value != []
  end

  defp regex(args, v1?) do
    pattern = args |> Map.get("pattern") |> Coerce.to_string()
    value = args |> Map.get("value") |> Coerce.to_string()

    case safe_search(pattern, value) do
      {:ok, valid?} ->
        {:ok, validity(valid?, v1?)}

      {:error, _reason} ->
        {:error, expression_error("Invalid regex pattern '#{pattern}'")}
    end
  end

  defp safe_search(pattern, value) do
    ECMA262.search(pattern, value)
  rescue
    error -> {:error, error}
  end

  defp length_check(args, v1?) do
    count = measure(Map.get(args, "value"))

    with {:ok, minimum} <- bound(args, "min"),
         {:ok, maximum} <- bound(args, "max") do
      valid? =
        (minimum == nil or count >= minimum) and (maximum == nil or count <= maximum)

      {:ok, validity(valid?, v1?)}
    end
  end

  defp measure(list) when is_list(list), do: length(list)
  defp measure(nil), do: 0
  defp measure(value), do: value |> Coerce.to_string() |> String.to_charlist() |> length()

  defp bound(args, key) do
    case Map.get(args, key) do
      nil ->
        {:ok, nil}

      value ->
        case Coerce.to_integer(value) do
          {:ok, integer} -> {:ok, integer}
          :error -> {:error, expression_error("Invalid #{key} for length: #{inspect(value)}")}
        end
    end
  end

  defp numeric?(args) do
    with {:ok, value} <- Coerce.to_float(Map.get(args, "value")),
         true <- within?(value, Map.get(args, "min"), &>=/2),
         true <- within?(value, Map.get(args, "max"), &<=/2) do
      true
    else
      _ -> false
    end
  end

  defp within?(_value, nil, _compare), do: true

  defp within?(value, bound, compare) do
    case Coerce.to_float(bound) do
      {:ok, limit} -> compare.(value, limit)
      :error -> false
    end
  end

  defp email(args, v1?) do
    value = args |> Map.get("value") |> Coerce.to_string()
    valid? = Regex.match?(@email, value)

    cond do
      not v1? ->
        valid?

      valid? ->
        %{"valid" => true}

      true ->
        %{
          "valid" => false,
          "code" => "INVALID_EMAIL",
          "message" => @email_message,
          "severity" => "error"
        }
    end
  end

  # -- logic --------------------------------------------------------------------

  defp logical(args, label, reducer, v1?) do
    case Map.get(args, "values") do
      values when is_list(values) and length(values) >= 2 ->
        {:ok, reducer.(values, &truthy_or_valid?(&1, v1?))}

      _other ->
        {:error, expression_error("#{label} requires at least 2 values")}
    end
  end

  defp truthy_or_valid?(%{"valid" => valid}, true) when is_boolean(valid), do: valid
  defp truthy_or_valid?(value, _v1?), do: Coerce.truthy?(value)

  # -- formatting ---------------------------------------------------------------

  defp format_string(args, ctx, v1?) do
    template = args |> Map.get("value") |> Coerce.to_string()

    if template == "" do
      {:ok, ""}
    else
      with {:ok, parts} <- Expression.parse(template) do
        interpolate(parts, ctx, v1?)
      end
    end
  end

  defp interpolate(parts, ctx, v1?) do
    {texts, effects} =
      Enum.map_reduce(parts, [], fn part, effects ->
        resolve_part(part, ctx, v1?, effects)
      end)

    {:ok, Enum.join(texts), effects}
  end

  defp resolve_part(part, %DataContext{} = ctx, v1?, effects) do
    dynamic = if v1?, do: adapt_part(part), else: part
    {value, found} = DataContext.resolve_dynamic_value(ctx, dynamic)
    {Coerce.to_string(value), effects ++ found}
  end

  defp resolve_part(part, nil, _v1?, effects), do: {Coerce.to_string(part), effects}

  # Template parts use `path`/`call`; v1.0 contexts expect `@path`/`@call`.
  defp adapt_part(%{"path" => path} = part)
       when is_binary(path) and not is_map_key(part, "componentId") and
              not is_map_key(part, "@path"),
       do: %{"@path" => path}

  defp adapt_part(%{"call" => name} = part)
       when is_binary(name) and not is_map_key(part, "@call") do
    args =
      case part["args"] do
        %{} = arguments -> Map.new(arguments, fn {key, value} -> {key, adapt_part(value)} end)
        _other -> %{}
      end

    call = %{"@call" => name, "args" => args}

    if Map.has_key?(part, "returnType"),
      do: Map.put(call, "returnType", part["returnType"]),
      else: call
  end

  defp adapt_part(part), do: part

  defp format_number(args, ctx, formatter) do
    with {:ok, value} <- number(Map.get(args, "value", 0)),
         {:ok, decimals} <- optional_integer(args, "decimals") do
      grouping = grouping(args)
      {:ok, formatter.decimal(value, decimals: decimals, grouping: grouping, locale: locale(ctx))}
    end
  end

  defp format_currency(args, ctx, formatter) do
    with {:ok, value} <- number(Map.get(args, "value", 0)),
         {:ok, decimals} <- optional_integer(args, "decimals") do
      currency = args |> Map.get("currency", "USD") |> python_str() |> String.upcase()

      {:ok,
       formatter.currency(value, currency,
         decimals: decimals || 2,
         grouping: grouping(args),
         locale: locale(ctx)
       )}
    end
  end

  defp grouping(args) do
    case Map.get(args, "grouping") do
      nil -> true
      value -> Coerce.truthy?(value)
    end
  end

  defp optional_integer(args, key) do
    case Map.get(args, key) do
      nil ->
        {:ok, nil}

      value ->
        case Coerce.to_integer(value) do
          {:ok, integer} when integer >= 0 -> {:ok, integer}
          {:ok, _negative} -> {:ok, 0}
          :error -> {:error, expression_error("Invalid #{key}: #{inspect(value)}")}
        end
    end
  end

  defp number(value) do
    case Coerce.to_float(value) do
      {:ok, float} -> {:ok, float}
      :error -> {:error, expression_error("Cannot convert to number: #{python_str(value)}")}
    end
  end

  defp format_date(args, ctx, formatter, v1?) do
    value = Map.get(args, "value")
    format = args |> Map.get("format", "yyyy-MM-dd") |> python_str()

    with true <- Coerce.truthy?(value),
         {:ok, utc, offset} <- parse_date(python_str(value)) do
      {:ok, render_date(utc, offset, format, formatter, locale(ctx), v1?)}
    else
      _ -> {:ok, ""}
    end
  end

  defp render_date(utc, _offset, "ISO", _formatter, _locale, _v1?) do
    {microsecond, _precision} = utc.microsecond

    [
      utc.year |> Integer.to_string() |> String.pad_leading(4, "0"),
      "-",
      pad2(utc.month),
      "-",
      pad2(utc.day),
      "T",
      pad2(utc.hour),
      ":",
      pad2(utc.minute),
      ":",
      pad2(utc.second),
      ".",
      microsecond |> div(1000) |> Integer.to_string() |> String.pad_leading(3, "0"),
      "Z"
    ]
    |> IO.iodata_to_binary()
  end

  # v1.0 formats the wall-clock fields of the value as written; v0.9
  # formats the UTC instant.
  defp render_date(utc, offset, format, formatter, locale, true) do
    local = DateTime.add(utc, offset, :second)
    formatter.date(local, format, locale: locale)
  end

  defp render_date(utc, _offset, format, formatter, locale, false),
    do: formatter.date(utc, format, locale: locale)

  # Python's `datetime.fromisoformat`: a date, optionally followed by a
  # separator and `HH[:MM[:SS[.ffffff]]]` and an offset. Elixir's parsers
  # need the seconds, so the missing parts are filled in first.
  @iso_timestamp ~r/\A(?<date>\d{4}-\d{2}-\d{2})(?:.(?<hour>\d{2})(?::(?<minute>\d{2})(?::(?<second>\d{2})(?<fraction>\.\d{1,6})?)?)?(?<offset>Z|[+-]\d{2}:\d{2})?)?\z/u

  defp parse_date(text) do
    text = text |> String.replace(~r/\A[\x00-\x20]+/, "") |> complete_time()

    case DateTime.from_iso8601(text) do
      {:ok, utc, offset} ->
        {:ok, utc, offset}

      {:error, _reason} ->
        naive_or_date(text)
    end
  end

  defp complete_time(text) do
    case Regex.named_captures(@iso_timestamp, text) do
      %{"hour" => hour} = parts when hour != "" ->
        minute = if parts["minute"] == "", do: "00", else: parts["minute"]
        second = if parts["second"] == "", do: "00", else: parts["second"]
        "#{parts["date"]}T#{hour}:#{minute}:#{second}#{parts["fraction"]}#{parts["offset"]}"

      _date_or_other ->
        text
    end
  end

  defp naive_or_date(text) do
    with {:error, _} <- NaiveDateTime.from_iso8601(text),
         {:error, _} <- date_only(text) do
      :error
    else
      {:ok, naive} -> {:ok, DateTime.from_naive!(naive, "Etc/UTC"), 0}
    end
  end

  defp date_only(text) do
    with {:ok, date} <- Date.from_iso8601(text) do
      NaiveDateTime.new(date, ~T[00:00:00])
    end
  end

  defp pad2(number), do: number |> Integer.to_string() |> String.pad_leading(2, "0")

  defp pluralize(args, ctx, formatter) do
    with {:ok, value} <- number(Map.get(args, "value", 0)) do
      category = plural_category(value, args, formatter, ctx)

      # An absent category falls back to `other`; an empty string is a
      # real answer ("render nothing").
      case Map.get(args, category) do
        nil -> {:ok, args |> Map.get("other") |> python_str_or_empty()}
        chosen -> {:ok, python_str(chosen)}
      end
    end
  end

  # An explicit `zero`/`one`/`two` argument wins for exactly that value.
  defp plural_category(value, args, formatter, ctx) do
    explicit = Enum.find(["zero", "one", "two"], &explicit_category?(&1, value, args))
    explicit || formatter.plural(value, locale: locale(ctx))
  end

  defp explicit_category?("zero", value, args), do: value == 0 and Map.has_key?(args, "zero")
  defp explicit_category?("one", value, args), do: value == 1 and Map.has_key?(args, "one")
  defp explicit_category?("two", value, args), do: value == 2 and Map.has_key?(args, "two")

  defp python_str_or_empty(nil), do: ""
  defp python_str_or_empty(value), do: python_str(value)

  # -- actions ------------------------------------------------------------------

  defp open_url(args) do
    case Map.get(args, "url") do
      url when is_binary(url) ->
        if String.trim(url) == "", do: {:ok, nil}, else: check_scheme(url)

      _other ->
        {:ok, nil}
    end
  end

  defp check_scheme(url) do
    cleaned =
      url
      |> String.replace(~r/\A[\x00-\x20]+/, "")
      |> String.replace(~r/[\t\r\n]/, "")

    scheme =
      case Regex.run(~r/\A([A-Za-z][A-Za-z0-9+.\-]*):/, cleaned) do
        [_, found] -> String.downcase(found)
        nil -> ""
      end

    if scheme in @allowed_url_schemes do
      {:ok, nil}
    else
      {:error, expression_error("Unsupported URL scheme: #{scheme}")}
    end
  end

  # -- helpers ------------------------------------------------------------------

  defp locale(%DataContext{locale: locale}), do: locale
  defp locale(_ctx), do: nil

  defp python_str(nil), do: "None"
  defp python_str(true), do: "True"
  defp python_str(false), do: "False"
  defp python_str(value), do: Coerce.to_string(value)

  defp expression_error(message), do: Error.new(:expression, "EXPRESSION_ERROR", message)
end

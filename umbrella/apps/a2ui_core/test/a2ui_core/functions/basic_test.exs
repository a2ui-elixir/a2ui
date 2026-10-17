defmodule A2UICore.Functions.BasicTest do
  @moduledoc false
  use ExUnit.Case, async: true

  alias A2UICore.Catalog.Basic, as: BasicCatalog
  alias A2UICore.Error
  alias A2UICore.Functions.Basic
  alias A2UICore.Resolution.DataContext
  alias A2UICore.State.DataModel

  defmodule ShoutFormatter do
    @moduledoc false
    @behaviour A2UICore.Formatter

    @impl true
    def decimal(value, opts), do: "DECIMAL(#{value},#{inspect(opts[:decimals])})"

    @impl true
    def currency(value, currency, _opts), do: "CURRENCY(#{value},#{currency})"

    @impl true
    def date(_value, format, _opts), do: "DATE(#{format})"

    @impl true
    def plural(_value, _opts), do: "few"
  end

  defmodule LocaleEcho do
    @moduledoc false
    @behaviour A2UICore.Formatter
    @impl true
    def decimal(_value, opts), do: opts[:locale]
    @impl true
    def currency(_value, _currency, opts), do: opts[:locale]
    @impl true
    def date(_value, _format, opts), do: opts[:locale]
    @impl true
    def plural(_value, _opts), do: "other"
  end

  defp call(version, name, args, context \\ nil, options \\ []) do
    execute = Map.fetch!(Basic.implementations(version, options), name)
    execute.(args, context)
  end

  defp value!(version, name, args, context \\ nil) do
    case call(version, name, args, context) do
      {:ok, value} -> value
      {:ok, value, []} -> value
    end
  end

  defp error!(version, name, args) do
    assert {:error, %Error{category: :expression, message: message}} =
             call(version, name, args)

    message
  end

  defp context(version, data) do
    DataContext.new("/", data_model: DataModel.new(data), catalog: BasicCatalog.catalog(version))
  end

  describe "implementations/2" do
    test "covers every function of the basic catalog" do
      expected =
        ~w(required regex length numeric email formatString formatNumber formatCurrency
           formatDate pluralize openUrl and or not)

      for version <- ["v0.9", "v1.0"] do
        assert Basic.implementations(version) |> Map.keys() |> Enum.sort() ==
                 Enum.sort(expected)
      end
    end
  end

  describe "required" do
    test "v0.9 returns booleans" do
      assert value!("v0.9", "required", %{"value" => "x"}) == true
      assert value!("v0.9", "required", %{"value" => ""}) == false
      assert value!("v0.9", "required", %{"value" => nil}) == false
      assert value!("v0.9", "required", %{"value" => []}) == false
      assert value!("v0.9", "required", %{"value" => 0}) == true
      assert value!("v0.9", "required", %{}) == false
    end

    test "v1.0 returns validation results" do
      assert value!("v1.0", "required", %{"value" => "x"}) == %{"valid" => true}
      assert value!("v1.0", "required", %{"value" => ""}) == %{"valid" => false}
    end
  end

  describe "regex" do
    test "matches anywhere in the value" do
      assert value!("v0.9", "regex", %{"value" => "abc123", "pattern" => "[0-9]+"}) == true
      assert value!("v0.9", "regex", %{"value" => "abc", "pattern" => "^[0-9]+$"}) == false
      assert value!("v1.0", "regex", %{"value" => "abc", "pattern" => "b"}) == %{"valid" => true}
    end

    test "an invalid pattern is an error" do
      assert error!("v0.9", "regex", %{"value" => "x", "pattern" => "("}) ==
               "Invalid regex pattern '('"
    end

    test "a pattern that backtracks without end is an error" do
      args = %{"value" => String.duplicate("a", 30) <> "!", "pattern" => "^(a+)+$"}
      assert error!("v1.0", "regex", args) =~ "took too many steps"
    end
  end

  describe "length" do
    test "strings count characters" do
      assert value!("v0.9", "length", %{"value" => "日本語", "min" => 3, "max" => 3}) == true
      assert value!("v0.9", "length", %{"value" => "abcd", "max" => 3}) == false
      assert value!("v0.9", "length", %{"value" => "ab", "min" => 3}) == false
    end

    test "lists count items" do
      assert value!("v0.9", "length", %{"value" => [1, 2], "min" => 2}) == true
    end

    test "nil has length zero and bounds are optional" do
      assert value!("v0.9", "length", %{"value" => nil, "min" => 0}) == true
      assert value!("v0.9", "length", %{"value" => "anything"}) == true
    end

    test "numeric string bounds are accepted" do
      assert value!("v0.9", "length", %{"value" => "abc", "min" => "2", "max" => "4"}) == true
    end

    test "v1.0 returns a validation result" do
      assert value!("v1.0", "length", %{"value" => "abcd", "max" => 3}) == %{"valid" => false}
    end

    test "invalid bounds are errors" do
      assert error!("v0.9", "length", %{"value" => "a", "min" => "x"}) ==
               ~s(Invalid min for length: "x")

      assert error!("v0.9", "length", %{"value" => "a", "max" => "y"}) ==
               ~s(Invalid max for length: "y")
    end
  end

  describe "numeric" do
    test "range checks" do
      assert value!("v0.9", "numeric", %{"value" => 5, "min" => 1, "max" => 10}) == true
      assert value!("v0.9", "numeric", %{"value" => "5", "min" => 6}) == false
      assert value!("v0.9", "numeric", %{"value" => 11, "max" => 10}) == false
      assert value!("v0.9", "numeric", %{"value" => 5, "min" => "abc"}) == false
    end

    test "non-numbers are invalid" do
      assert value!("v0.9", "numeric", %{"value" => "abc"}) == false
      assert value!("v0.9", "numeric", %{"value" => nil}) == false
      assert value!("v1.0", "numeric", %{"value" => "7"}) == %{"valid" => true}
    end
  end

  describe "email" do
    test "v0.9 returns booleans" do
      assert value!("v0.9", "email", %{"value" => "user@example.com"}) == true
      assert value!("v0.9", "email", %{"value" => "nope"}) == false
    end

    test "v1.0 adds the failure details" do
      assert value!("v1.0", "email", %{"value" => "user@example.com"}) == %{"valid" => true}

      assert value!("v1.0", "email", %{"value" => "nope"}) == %{
               "valid" => false,
               "code" => "INVALID_EMAIL",
               "message" => "Please enter a valid email address (e.g. user@example.com).",
               "severity" => "error"
             }
    end
  end

  describe "and / or / not" do
    test "combine truthiness" do
      assert value!("v0.9", "and", %{"values" => [true, 1, "x"]}) == true
      assert value!("v0.9", "and", %{"values" => [true, 0]}) == false
      assert value!("v0.9", "or", %{"values" => [false, 0, "x"]}) == true
      assert value!("v0.9", "or", %{"values" => [false, nil]}) == false
      assert value!("v0.9", "not", %{"value" => ""}) == true
      assert value!("v0.9", "not", %{"value" => "x"}) == false
    end

    test "need at least two values" do
      assert error!("v0.9", "and", %{"values" => [true]}) ==
               "AndFunction requires at least 2 values"

      assert error!("v0.9", "or", %{"values" => "nope"}) ==
               "OrFunction requires at least 2 values"

      assert error!("v0.9", "and", %{}) == "AndFunction requires at least 2 values"
    end

    test "v1.0 reads validation results by validity" do
      invalid = %{"valid" => false}
      valid = %{"valid" => true}

      assert value!("v1.0", "and", %{"values" => [valid, invalid]}) == false
      assert value!("v1.0", "or", %{"values" => [invalid, valid]}) == true
      assert value!("v1.0", "not", %{"value" => invalid}) == true
    end

    test "v0.9 treats validation-shaped objects as ordinary objects" do
      invalid = %{"valid" => false}
      assert value!("v0.9", "and", %{"values" => [invalid, invalid]}) == true
      assert value!("v0.9", "not", %{"value" => invalid}) == false
    end
  end

  describe "formatString" do
    test "an empty template is an empty string" do
      assert value!("v0.9", "formatString", %{"value" => ""}) == ""
      assert value!("v0.9", "formatString", %{}) == ""
    end

    test "interpolates bindings" do
      ctx = context("v0.9", %{"user" => %{"name" => "Ada"}, "n" => 3})
      args = %{"value" => "Hi ${/user/name}, you have ${/n} new."}

      assert value!("v0.9", "formatString", args, ctx) == "Hi Ada, you have 3 new."
    end

    test "v1.0 evaluates the same templates" do
      ctx = context("v1.0", %{"user" => %{"name" => "Ada"}})

      assert value!("v1.0", "formatString", %{"value" => "Hi ${/user/name}"}, ctx) == "Hi Ada"
    end

    test "nested calls" do
      ctx = context("v1.0", %{"n" => 1234.5})

      args = %{"value" => "Total: ${formatNumber(value: /n, decimals: 1)}"}
      assert value!("v1.0", "formatString", args, ctx) == "Total: 1,234.5"
    end

    test "@index gives a template's position in its list" do
      scope = "v1.0" |> context(%{"items" => ["a", "b", "c"]}) |> DataContext.nested("items/2", 2)

      args = %{"value" => "#${@index(offset: 1)}: ${.}"}
      assert value!("v1.0", "formatString", args, scope) == "#3: c"
    end

    test "missing bindings render empty and surface a warning" do
      ctx = context("v0.9", %{})

      assert {:ok, "Hi !", [{:warning, %{code: "MISSING_DATA_BINDING", path: "/name"}}]} =
               call("v0.9", "formatString", %{"value" => "Hi ${/name}!"}, ctx)
    end

    test "without a context parts are rendered as written" do
      assert value!("v0.9", "formatString", %{"value" => "a ${1} b"}) == "a 1 b"
    end

    test "a template that does not parse is an error" do
      assert error!("v0.9", "formatString", %{"value" => "${oops"}) =~ "Unclosed interpolation"
    end
  end

  describe "formatNumber" do
    test "default formatting" do
      assert value!("v0.9", "formatNumber", %{"value" => 1_234_567.891}) == "1,234,567.891"
    end

    test "decimals and grouping" do
      assert value!("v0.9", "formatNumber", %{"value" => 1234.5, "decimals" => 2}) == "1,234.50"

      assert value!("v0.9", "formatNumber", %{"value" => 1234.5, "grouping" => false}) ==
               "1234.5"

      assert value!("v0.9", "formatNumber", %{"value" => 1234.5, "decimals" => -3}) == "1,234"
    end

    test "numeric strings are accepted, others are errors" do
      assert value!("v0.9", "formatNumber", %{"value" => "12.5"}) == "12.5"

      assert error!("v0.9", "formatNumber", %{"value" => "abc"}) ==
               "Cannot convert to number: abc"

      assert error!("v0.9", "formatNumber", %{"value" => 1, "decimals" => "x"}) ==
               ~s(Invalid decimals: "x")
    end
  end

  describe "formatCurrency" do
    test "defaults to USD with two decimals" do
      assert value!("v0.9", "formatCurrency", %{"value" => 1234.5}) == "$1,234.50"
    end

    test "currency codes are case-insensitive" do
      assert value!("v0.9", "formatCurrency", %{"value" => 5, "currency" => "eur"}) == "€5.00"

      assert value!("v0.9", "formatCurrency", %{
               "value" => 5,
               "currency" => "JPY",
               "decimals" => 0
             }) ==
               "¥5"
    end

    test "invalid numbers are errors" do
      assert error!("v0.9", "formatCurrency", %{"value" => "abc"}) ==
               "Cannot convert to number: abc"
    end
  end

  describe "formatDate" do
    test "formats the UTC instant in v0.9" do
      args = %{"value" => "2026-08-26T23:30:00-05:00", "format" => "yyyy-MM-dd HH:mm"}
      assert value!("v0.9", "formatDate", args) == "2026-08-27 04:30"
    end

    test "formats the wall-clock fields in v1.0" do
      args = %{"value" => "2026-08-26T23:30:00-05:00", "format" => "yyyy-MM-dd HH:mm"}
      assert value!("v1.0", "formatDate", args) == "2026-08-26 23:30"
    end

    test "the default format is yyyy-MM-dd" do
      assert value!("v0.9", "formatDate", %{"value" => "2026-08-26T10:00:00Z"}) == "2026-08-26"
    end

    test "ISO renders the UTC instant with milliseconds" do
      args = %{"value" => "2026-08-26T15:04:09.123456Z", "format" => "ISO"}
      assert value!("v0.9", "formatDate", args) == "2026-08-26T15:04:09.123Z"
    end

    test "naive timestamps and bare dates are UTC" do
      assert value!("v0.9", "formatDate", %{"value" => "2026-08-26T10:15:00", "format" => "HH:mm"}) ==
               "10:15"

      assert value!("v0.9", "formatDate", %{"value" => "2026-08-26", "format" => "HH:mm"}) ==
               "00:00"
    end

    test "the time may stop at the hour or the minute, as a date-time input writes it" do
      format = "yyyy-MM-dd HH:mm:ss"

      assert value!("v1.0", "formatDate", %{"value" => "2026-10-17T19:30", "format" => format}) ==
               "2026-10-17 19:30:00"

      assert value!("v1.0", "formatDate", %{"value" => "2026-10-17 19:30", "format" => format}) ==
               "2026-10-17 19:30:00"

      assert value!("v1.0", "formatDate", %{"value" => "2026-10-17T19", "format" => format}) ==
               "2026-10-17 19:00:00"

      assert value!("v0.9", "formatDate", %{
               "value" => "2026-10-17T19:30+02:00",
               "format" => format
             }) == "2026-10-17 17:30:00"

      assert value!("v1.0", "formatDate", %{
               "value" => "2026-10-17T19:30:05.25Z",
               "format" => format
             }) == "2026-10-17 19:30:05"

      assert value!("v1.0", "formatDate", %{"value" => "2026-10-17Tx", "format" => format}) == ""
    end

    test "leading whitespace is ignored" do
      assert value!("v0.9", "formatDate", %{"value" => "  2026-08-26T10:00:00Z"}) == "2026-08-26"
    end

    test "unparseable and empty values render empty" do
      assert value!("v0.9", "formatDate", %{"value" => "not a date"}) == ""
      assert value!("v0.9", "formatDate", %{"value" => ""}) == ""
      assert value!("v0.9", "formatDate", %{"value" => nil}) == ""
    end
  end

  describe "pluralize" do
    test "picks the category by the plural rules" do
      args = %{"value" => 1, "one" => "item", "other" => "items"}
      assert value!("v0.9", "pluralize", args) == "item"
      assert value!("v0.9", "pluralize", %{args | "value" => 5}) == "items"
    end

    test "explicit zero, one and two win" do
      args = %{"zero" => "none", "one" => "single", "two" => "pair", "other" => "many"}

      assert value!("v0.9", "pluralize", Map.put(args, "value", 0)) == "none"
      assert value!("v0.9", "pluralize", Map.put(args, "value", 1)) == "single"
      assert value!("v0.9", "pluralize", Map.put(args, "value", 2)) == "pair"
      assert value!("v0.9", "pluralize", Map.put(args, "value", 3)) == "many"
    end

    test "falls back to other and then to the empty string" do
      assert value!("v0.9", "pluralize", %{"value" => 0, "other" => "items"}) == "items"
      assert value!("v0.9", "pluralize", %{"value" => 5}) == ""
    end

    test "an empty category is an answer" do
      assert value!("v0.9", "pluralize", %{"value" => 1, "one" => "", "other" => "items"}) == ""
    end

    test "non-numbers are errors" do
      assert error!("v0.9", "pluralize", %{"value" => "x"}) == "Cannot convert to number: x"
    end
  end

  describe "openUrl" do
    test "allowed schemes" do
      for url <- ["http://a.example", "HTTPS://a.example", "mailto:a@b.example", "tel:+15551234"] do
        assert value!("v0.9", "openUrl", %{"url" => url}) == nil
      end
    end

    test "disallowed schemes are errors" do
      assert error!("v0.9", "openUrl", %{"url" => "javascript:alert(1)"}) ==
               "Unsupported URL scheme: javascript"

      assert error!("v0.9", "openUrl", %{"url" => "  JavaScript:alert(1)"}) ==
               "Unsupported URL scheme: javascript"

      assert error!("v0.9", "openUrl", %{"url" => "java\tscript:alert(1)"}) ==
               "Unsupported URL scheme: javascript"

      assert error!("v0.9", "openUrl", %{"url" => "/relative"}) == "Unsupported URL scheme: "
    end

    test "empty and non-string urls are ignored" do
      assert value!("v0.9", "openUrl", %{"url" => "   "}) == nil
      assert value!("v0.9", "openUrl", %{"url" => 5}) == nil
      assert value!("v0.9", "openUrl", %{}) == nil
    end
  end

  describe "formatter option" do
    test "replaces the locale-sensitive formatting" do
      options = [formatter: ShoutFormatter]

      assert {:ok, "DECIMAL(5.0,2)"} =
               call("v0.9", "formatNumber", %{"value" => 5, "decimals" => 2}, nil, options)

      assert {:ok, "CURRENCY(5.0,USD)"} =
               call("v0.9", "formatCurrency", %{"value" => 5}, nil, options)

      assert {:ok, "DATE(yyyy)"} =
               call(
                 "v0.9",
                 "formatDate",
                 %{"value" => "2026-01-01T00:00:00Z", "format" => "yyyy"},
                 nil,
                 options
               )

      assert {:ok, "FEW"} =
               call(
                 "v0.9",
                 "pluralize",
                 %{"value" => 3, "few" => "FEW", "other" => "x"},
                 nil,
                 options
               )
    end

    test "the context locale is passed through" do
      ctx = %{context("v0.9", %{}) | locale: "de-DE"}

      assert {:ok, "de-DE"} =
               call("v0.9", "formatNumber", %{"value" => 1}, ctx, formatter: LocaleEcho)
    end
  end
end

defmodule A2UICore.Formatter.DefaultTest do
  @moduledoc false
  use ExUnit.Case, async: true

  alias A2UICore.Formatter.Default

  doctest A2UICore.Formatter.Default

  @nbsp " "

  describe "decimal/2" do
    test "groups thousands and keeps up to three fraction digits" do
      assert Default.decimal(1_234_567, []) == "1,234,567"
      assert Default.decimal(1234.5678, []) == "1,234.568"
      assert Default.decimal(0.5, []) == "0.5"
      assert Default.decimal(-1234.5, []) == "-1,234.5"
    end

    test "fixed decimals pad and round" do
      assert Default.decimal(1234.567, decimals: 2) == "1,234.57"
      assert Default.decimal(5, decimals: 2) == "5.00"
      assert Default.decimal(1.0, decimals: 0) == "1"
    end

    test "rounds half to even on the shortest decimal form" do
      assert Default.decimal(2.675, decimals: 2) == "2.68"
      assert Default.decimal(0.125, decimals: 2) == "0.12"
      assert Default.decimal(0.135, decimals: 2) == "0.14"
      assert Default.decimal(2.5, decimals: 0) == "2"
      assert Default.decimal(3.5, decimals: 0) == "4"
    end

    test "grouping can be turned off" do
      assert Default.decimal(1_234_567.891, grouping: false) == "1234567.891"
    end

    test "very large and very small magnitudes" do
      assert Default.decimal(1.0e20, []) == "100,000,000,000,000,000,000"
      assert Default.decimal(1.0e-7, []) == "0"
      assert Default.decimal(1.0e-7, decimals: 8) == "0.00000010"
    end

    test "negative values that round to zero keep the sign" do
      assert Default.decimal(-0.0001, decimals: 2) == "-0.00"
    end
  end

  describe "currency/3" do
    test "symbol currencies attach directly" do
      assert Default.currency(99.99, "USD", []) == "$99.99"
      assert Default.currency(1_234.5, "EUR", []) == "€1,234.50"
      assert Default.currency(-5, "GBP", []) == "-£5.00"
      assert Default.currency(1000, "JPY", decimals: 0) == "¥1,000"
    end

    test "alphabetic symbols are separated by a no-break space" do
      assert Default.currency(1234.56, "CHF", []) == "CHF#{@nbsp}1,234.56"
      assert Default.currency(10, "XYZ", []) == "XYZ#{@nbsp}10.00"
    end

    test "symbols that end in a letter-like character keep the space only for letters" do
      assert Default.currency(1, "CAD", []) == "CA$1.00"
      assert Default.currency(1, "XOF", []) == "F CFA#{@nbsp}1.00"
    end
  end

  describe "date/3" do
    @moment ~U[2026-08-26 15:04:09Z]

    test "numeric tokens" do
      assert Default.date(@moment, "yyyy-MM-dd HH:mm:ss", []) == "2026-08-26 15:04:09"
      assert Default.date(@moment, "yy/M/d H", []) == "26/8/26 15"
    end

    test "names" do
      assert Default.date(@moment, "EEEE, MMMM d, yyyy", []) == "Wednesday, August 26, 2026"
      assert Default.date(@moment, "E MMM", []) == "Wed Aug"
    end

    test "twelve-hour clock" do
      assert Default.date(@moment, "h:mm a", []) == "3:04 PM"
      assert Default.date(~U[2026-01-01 00:30:00Z], "hh:mm a", []) == "12:30 AM"
      assert Default.date(~U[2026-01-01 12:00:00Z], "h a", []) == "12 PM"
    end

    test "punctuation and unknown letters pass through" do
      assert Default.date(@moment, "yyyy/x%", []) == "2026/x%"
    end

    test "quoted text is literal, and two quotes are a quote" do
      assert Default.date(@moment, "EEEE, MMMM d, yyyy 'at' h:mm a", []) ==
               "Wednesday, August 26, 2026 at 3:04 PM"

      assert Default.date(@moment, "h 'o''clock' a", []) == "3 o'clock PM"
      assert Default.date(@moment, "''yy", []) == "'26"
      assert Default.date(@moment, "yyyy 'unclosed MM", []) == "2026 unclosed MM"
    end

    test "accepts any map with the date and time fields" do
      fields = %{year: 2020, month: 2, day: 29, hour: 0, minute: 0, second: 0}
      assert Default.date(fields, "dd MMM yyyy", []) == "29 Feb 2020"
    end
  end

  describe "plural/2" do
    test "english one/other" do
      assert Default.plural(1, []) == "one"
      assert Default.plural(-1, []) == "one"
      assert Default.plural(0, []) == "other"
      assert Default.plural(2, []) == "other"
      assert Default.plural(1.5, []) == "other"
    end
  end
end

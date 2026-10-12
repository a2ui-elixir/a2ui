defmodule A2UICore.Formatter do
  @moduledoc """
  Locale-sensitive formatting for the basic catalog's `formatNumber`,
  `formatCurrency`, `formatDate` and `pluralize` functions.

  `a2ui_core` carries no locale database. `A2UICore.Formatter.Default`
  implements the `en-US` conventions the reference suites exercise and
  uses them for every locale tag. A host that needs CLDR data for other
  locales passes its own module (for example one backed by `ex_cldr`) as
  the `:formatter` option when building a catalog's functions.

  Every callback receives the requested BCP 47 `:locale` (or `nil`) in
  `opts`; an implementation that does not know the locale should format
  as `en-US`, as the reference does.
  """

  @moduledoc since: "0.1.0"

  @typedoc "Formatting options common to all callbacks."
  @type opts :: [locale: String.t() | nil]

  @doc """
  Formats a decimal number. `:decimals` fixes the fraction digit count
  (default: up to three, trailing zeros dropped); `:grouping` toggles the
  thousands separator.
  """
  @callback decimal(number(), [
              {:decimals, non_neg_integer() | nil}
              | {:grouping, boolean()}
              | {:locale, String.t() | nil}
            ]) ::
              String.t()

  @doc """
  Formats a monetary amount in the ISO 4217 `currency`. `:decimals`
  defaults to 2.
  """
  @callback currency(number(), String.t(), [
              {:decimals, non_neg_integer()}
              | {:grouping, boolean()}
              | {:locale, String.t() | nil}
            ]) ::
              String.t()

  @doc """
  Formats a date-time with a TR35 style pattern (`yyyy-MM-dd`, `MMM d`,
  `hh:mm a`, …).
  """
  @callback date(DateTime.t() | NaiveDateTime.t(), String.t(), opts()) :: String.t()

  @doc """
  The CLDR plural category (`"zero"`, `"one"`, `"two"`, `"few"`, `"many"`
  or `"other"`) of `number`.
  """
  @callback plural(number(), opts()) :: String.t()
end

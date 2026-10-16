defmodule Gallery.Scenarios.Data do
  @moduledoc """
  A market watch: a list repeated over the data model with a template,
  paths relative to each item next to absolute ones, a template nested
  in a template, `@index`, the formatting functions, and an agent that
  pushes a new quote to a single path every second. Controls add an
  item, replace the whole data model, switch the currency and delete a
  bound path.
  """

  use Gallery.Scenario

  def id, do: "data"
  def title, do: "Data binding"

  def summary,
    do:
      "Templates over lists, relative and absolute paths, formatting functions, and live updates to single paths."

  def features,
    do: [
      "List templates",
      "relative paths",
      "nested templates",
      "@index",
      "formatCurrency",
      "formatNumber",
      "formatDate",
      "pluralize",
      "updateDataModel: path, root, delete",
      "two-way binding in a template",
      "MISSING_DATA_BINDING",
      "Icon svgPath"
    ]

  @note "Quotes are simulated: the agent sends one every second."

  # Triangles pointing up and down, for Icon's svgPath.
  @up "M7 15l5-6 5 6z"
  @down "M7 9l5 6 5-6z"

  @stocks [
    %{
      "symbol" => "ACME",
      "name" => "Acme Corporation",
      "base" => 182.4,
      "volume" => 1_204_331,
      "tags" => ["industrials", "large cap"]
    },
    %{
      "symbol" => "GLBX",
      "name" => "Globex",
      "base" => 54.12,
      "volume" => 380_120,
      "tags" => ["energy"]
    },
    %{
      "symbol" => "INIT",
      "name" => "Initech",
      "base" => 12.03,
      "volume" => 92_004,
      "tags" => ["software", "small cap"]
    }
  ]

  @extra %{
    "symbol" => "HOOL",
    "name" => "Hooli",
    "base" => 731.9,
    "volume" => 2_870_455,
    "tags" => ["software", "large cap", "new"]
  }

  def messages, do: [create("market", data: model(), components: market())]

  @doc "The data model the surface starts with."
  def model do
    %{
      "currency" => "EUR",
      "note" => @note,
      "updatedAt" => "2026-10-16T09:30:00Z",
      "count" => length(@stocks),
      "stocks" => Enum.map(@stocks, &stock(&1, 0))
    }
  end

  defp stock(stock, n) do
    stock
    |> Map.take(~w(symbol name volume tags))
    |> Map.put("watched", stock["symbol"] == "ACME")
    |> Map.put("quote", price_quote(stock, n))
  end

  # A price that drifts around the base, the same for the same tick.
  defp price_quote(stock, n) do
    phase = :erlang.phash2(stock["symbol"], 100) / 10
    change = Float.round(2.5 * :math.sin(n / 4 + phase), 2)
    price = Float.round(stock["base"] * (1 + change / 100), 2)
    %{"price" => price, "change" => change, "arrow" => if(change < 0, do: @down, else: @up)}
  end

  defp market do
    [
      %{
        "id" => "root",
        "component" => "Column",
        "children" => ["title", "note", "status", "stocks"]
      },
      text("title", "## Market watch"),
      text("note", path("/note"), %{"variant" => "caption"}),
      %{
        "id" => "status",
        "component" => "Row",
        "justify" => "spaceBetween",
        "align" => "center",
        "children" => ["summary", "updated"]
      },
      text(
        "updated",
        call("formatString", %{
          "value" => "Updated at ${formatDate(value: ${/updatedAt}, format: 'HH:mm:ss')} UTC"
        }),
        %{"variant" => "caption", "accessibility" => %{"live" => "off"}}
      ),
      text(
        "summary",
        call("pluralize", %{
          "value" => path("/count"),
          "one" => call("formatString", %{"value" => "One stock, prices in ${/currency}."}),
          "other" =>
            call("formatString", %{"value" => "${/count} stocks, prices in ${/currency}."})
        })
      ),
      %{
        "id" => "stocks",
        "component" => "List",
        "children" => %{"componentId" => "stockRow", "path" => "/stocks"}
      },
      # The template: every path below is relative to one stock, except
      # /currency.
      %{"id" => "stockRow", "component" => "Card", "child" => "stockBody"},
      %{
        "id" => "stockBody",
        "component" => "Row",
        "align" => "center",
        "children" => ["position", "names", "figures", "watch"]
      },
      text("position", call("formatString", %{"value" => "#${@index(offset: 1)}"}), %{
        "variant" => "caption"
      }),
      %{
        "id" => "names",
        "component" => "Column",
        "weight" => 1,
        "children" => ["symbol", "name", "tags"]
      },
      text("symbol", call("formatString", %{"value" => "#### ${symbol}"})),
      text("name", path("name"), %{"variant" => "caption"}),
      %{
        "id" => "tags",
        "component" => "List",
        "direction" => "horizontal",
        "children" => %{"componentId" => "tag", "path" => "tags"}
      },
      text("tag", path("."), %{"variant" => "caption"}),
      %{
        "id" => "figures",
        "component" => "Column",
        "align" => "end",
        "children" => ["price", "change", "volume"]
      },
      text(
        "price",
        call("formatString", %{
          "value" => "#### ${formatCurrency(value: ${quote/price}, currency: ${/currency})}"
        })
      ),
      %{
        "id" => "change",
        "component" => "Row",
        "align" => "center",
        "children" => ["arrow", "percent"]
      },
      %{
        "id" => "arrow",
        "component" => "Icon",
        "name" => %{"svgPath" => path("quote/arrow")},
        "accessibility" => %{
          "label" => call("formatString", %{"value" => "${quote/change} percent"})
        }
      },
      text(
        "percent",
        call("formatString", %{
          "value" => "${formatNumber(value: ${quote/change}, decimals: 2)} %"
        }),
        %{"variant" => "caption"}
      ),
      text(
        "volume",
        call("formatString", %{"value" => "Volume ${formatNumber(value: ${volume})}"}),
        %{"variant" => "caption"}
      ),
      %{
        "id" => "watch",
        "component" => "CheckBox",
        "label" => "Watch",
        "value" => path("watched")
      }
    ]
  end

  # One stock a tick, in turn, for five minutes: a new quote at its path,
  # without touching the rest of the item (such as what the user ticked).
  def tick(n) when n > 300, do: nil

  def tick(n) do
    index = rem(n - 1, length(@stocks))

    [
      data("market", "/stocks/#{index}/quote", price_quote(Enum.at(@stocks, index), n)),
      data(
        "market",
        "/updatedAt",
        DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()
      )
    ]
  end

  def controls,
    do: [
      {"add", "Add a stock"},
      {"reset", "Replace the whole data model"},
      {"usd", "Prices in dollars"},
      {"eur", "Prices in euros"},
      {"delete_note", "Delete /note"},
      {"restore_note", "Restore /note"}
    ]

  def control("add"),
    do: [{100, [data("market", "/stocks/3", stock(@extra, 0)), data("market", "/count", 4)]}]

  def control("reset"), do: [{100, data("market", "/", model())}]
  def control("usd"), do: [{100, data("market", "/currency", "USD")}]
  def control("eur"), do: [{100, data("market", "/currency", "EUR")}]
  def control("delete_note"), do: [{100, data("market", "/note")}]
  def control("restore_note"), do: [{100, data("market", "/note", @note)}]
  def control(_id), do: []
end

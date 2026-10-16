defmodule Gallery.Scenarios.V09 do
  @moduledoc """
  Protocol v0.9 on the same renderer: its message shapes (components and
  data in their own messages), its binding syntax (`path`, `call` with
  `returnType`), heading variants, checks that return booleans, and the
  surface theme v0.9 defines (`primaryColor`, `agentDisplayName`,
  `iconUrl`). The surface sends its data model with every message.
  """

  use Gallery.Scenario

  @catalog "https://a2ui.org/specification/v0_9/catalogs/basic/catalog.json"

  def id, do: "v0_9"
  def title, do: "Protocol v0.9"

  def summary,
    do:
      "The v0.9 wire format next to v1.0: separate component and data messages, path/call bindings, heading variants, boolean checks and a themed surface."

  def features,
    do: [
      "v0.9 messages",
      "theme: primaryColor",
      "theme: agentDisplayName, iconUrl",
      "path / call bindings",
      "Text h1–h5",
      "boolean checks",
      "templates",
      "sendDataModel (v0.9)"
    ]

  def catalogs, do: [Gallery.Catalogs.basic("v0.9.1")]

  @books [
    %{
      "id" => "b1",
      "title" => "The Analytical Engine",
      "author" => "Ada Lovelace",
      "year" => 1843,
      "available" => true
    },
    %{
      "id" => "b2",
      "title" => "On Computable Numbers",
      "author" => "Alan Turing",
      "year" => 1936,
      "available" => false
    },
    %{
      "id" => "b3",
      "title" => "A Mathematical Theory of Communication",
      "author" => "Claude Shannon",
      "year" => 1948,
      "available" => true
    }
  ]

  defp v09(kind, body), do: %{"version" => "v0.9", kind => body}
  defp bind(path), do: %{"path" => path}

  defp fun(name, args, return_type),
    do: %{"call" => name, "args" => args, "returnType" => return_type}

  defp label(id, text, variant \\ "body"),
    do: %{"id" => id, "component" => "Text", "text" => text, "variant" => variant}

  def messages do
    [
      v09("createSurface", %{
        "surfaceId" => "library",
        "catalogId" => @catalog,
        "sendDataModel" => true,
        "theme" => %{
          "primaryColor" => "#7048e8",
          "agentDisplayName" => "Library assistant",
          "iconUrl" => GalleryWeb.Endpoint.url() <> "/media/avatar.svg"
        }
      }),
      v09("updateComponents", %{"surfaceId" => "library", "components" => library()}),
      v09("updateDataModel", %{
        "surfaceId" => "library",
        "path" => "/",
        "value" => %{
          "query" => "",
          "reader" => "",
          "books" => @books,
          "count" => length(@books),
          "status" => ""
        }
      })
    ]
  end

  defp library do
    [
      %{
        "id" => "root",
        "component" => "Column",
        "children" => ["title", "subtitle", "reader", "books", "status"]
      },
      label("title", "Library", "h2"),
      label(
        "subtitle",
        fun(
          "formatString",
          %{"value" => "${/count} books on the shelf. Borrow one with your library card number."},
          "string"
        ),
        "caption"
      ),
      %{
        "id" => "reader",
        "component" => "TextField",
        "label" => "Library card number",
        "value" => bind("/reader"),
        "checks" => [
          %{
            "condition" =>
              fun("regex", %{"value" => bind("/reader"), "pattern" => "^[0-9]{6}$"}, "boolean"),
            "message" => "Six digits, as printed on your card."
          }
        ]
      },
      %{
        "id" => "books",
        "component" => "List",
        "children" => %{"componentId" => "book", "path" => "/books"}
      },
      %{"id" => "book", "component" => "Card", "child" => "bookRow"},
      %{
        "id" => "bookRow",
        "component" => "Row",
        "align" => "center",
        "children" => ["bookText", "borrow"]
      },
      %{
        "id" => "bookText",
        "component" => "Column",
        "weight" => 1,
        "children" => ["bookTitle", "bookAuthor"]
      },
      label("bookTitle", bind("title"), "h4"),
      label(
        "bookAuthor",
        fun("formatString", %{"value" => "${author}, ${year}"}, "string"),
        "caption"
      ),
      %{
        "id" => "borrow",
        "component" => "Button",
        "variant" => "primary",
        "child" => "borrowLabel",
        "checks" => [
          %{
            "condition" =>
              fun(
                "and",
                %{
                  "values" => [
                    bind("available"),
                    fun(
                      "regex",
                      %{"value" => bind("/reader"), "pattern" => "^[0-9]{6}$"},
                      "boolean"
                    )
                  ]
                },
                "boolean"
              ),
            "message" => "Available books only, with a valid card number."
          }
        ],
        "action" => %{
          "event" => %{
            "name" => "borrow",
            "context" => %{"bookId" => bind("id"), "title" => bind("title")}
          }
        }
      },
      label("borrowLabel", "Borrow"),
      label("status", bind("/status"))
    ]
  end

  # The data model came along (sendDataModel), with the card number.
  def reply(%{"action" => %{"name" => "borrow", "context" => context}}, data_models) do
    reader = get_in(data_models, ["library", "reader"])
    books = get_in(data_models, ["library", "books"]) || @books
    index = Enum.find_index(books, &(&1["id"] == context["bookId"]))

    [
      {250, {:text, "Card #{reader} borrows \"#{context["title"]}\"."}},
      {300,
       [
         v09("updateDataModel", %{
           "surfaceId" => "library",
           "path" => "/books/#{index}/available",
           "value" => false
         }),
         v09("updateDataModel", %{
           "surfaceId" => "library",
           "path" => "/status",
           "value" => "\"#{context["title"]}\" is yours for three weeks."
         })
       ]}
    ]
  end

  def reply(_message, _data_models), do: []

  def controls, do: [{"return", "Return every book"}]

  def control("return") do
    [
      {100,
       [
         v09("updateDataModel", %{
           "surfaceId" => "library",
           "path" => "/books",
           "value" => Enum.map(@books, &Map.put(&1, "available", true))
         }),
         v09("updateDataModel", %{
           "surfaceId" => "library",
           "path" => "/status",
           "value" => "Every book is back on the shelf."
         })
       ]}
    ]
  end

  def control(_id), do: []
end

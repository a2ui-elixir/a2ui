defmodule RestaurantAgent.UI do
  @moduledoc """
  The surfaces the agent builds in code with `A2UIAgent.Builder`: the
  booking form, the confirmation, and the restaurant list for the
  protocol versions and formats the scripted model does not write with
  the macro (`RestaurantAgent.Model`).

  The same trees serve protocol v0.9 and v1.0: the builder writes the
  keys of the version (`path`/`call` or `@path`/`@call`).
  """

  import A2UIAgent.Builder
  import A2UIAgent.Builder.Basic

  alias RestaurantAgent.Catalogs

  @theme %{
    "primaryColor" => "#c0392b",
    "agentDisplayName" => "Restaurant finder"
  }

  @doc """
  The list of `restaurants` on a new surface: a card per restaurant in a
  horizontal list, repeated over the data model with a template. Option:
  `:rating`, show the restaurant catalog's `Rating` (default: in v1.0),
  else the stars as text.
  """
  @spec list(String.t(), String.t(), [map()], String.t(), String.t(), keyword()) :: [map()]
  def list(surface_id, heading, restaurants, base_url, version, options \\ []) do
    v1? = version == "v1.0"

    stars =
      if Keyword.get(options, :rating, v1?),
        do:
          component("Rating",
            catalog_id: Catalogs.restaurant_id(),
            value: bind("rating"),
            label: call("formatString", value: "${reviews} reviews")
          ),
        else: text(text: call("formatString", value: "${stars} ${rating}"), variant: "caption")

    name =
      if v1?,
        do: text(text: call("formatString", value: "#### ${name}")),
        else: text(text: bind("name"), variant: "h4")

    card =
      card(
        id: "card",
        child:
          column(
            justify: "spaceBetween",
            children: [
              column(
                children: [
                  image(
                    url: bind("image"),
                    description: bind("dish"),
                    fit: "cover",
                    variant: "mediumFeature"
                  ),
                  name,
                  text(
                    text: call("formatString", value: "${cuisine} · ${price} · ${distance} km"),
                    variant: "caption"
                  ),
                  stars
                ]
              ),
              button(
                id: "book",
                child: text(text: "Book a table"),
                action: event("book", restaurantId: bind("id"), name: bind("name"))
              )
            ]
          )
      )

    tree =
      column(
        id: "root",
        children: [
          heading(heading, version),
          text(
            id: "summary",
            variant: "caption",
            text:
              call("pluralize",
                value: bind("/count"),
                one: "One place nearby.",
                other: call("formatString", value: "${/count} places nearby, nearest first.")
              )
          ),
          list(id: "list", direction: "horizontal", children: child_list("/restaurants", card))
        ]
      )

    data = %{
      "count" => length(restaurants),
      "restaurants" => Enum.map(restaurants, &item(&1, base_url))
    }

    surface(surface_id, tree, data, version, send_data_model: false)
  end

  @doc "A restaurant as the list's data model holds it."
  @spec item(map(), String.t()) :: map()
  def item(restaurant, base_url) do
    restaurant
    |> Map.take(~w(id name cuisine rating reviews price distance dish))
    |> Map.put("image", "#{base_url}/images/#{restaurant["id"]}.svg")
    |> Map.put("stars", stars(restaurant["rating"]))
  end

  defp stars(rating) do
    full = round(rating)
    String.duplicate("★", full) <> String.duplicate("☆", 5 - full)
  end

  @doc """
  The booking form for `restaurant`: a header with its picture, your
  details, your table, and the booking's summary next to the button.
  Options:

    * `:availability` — show whether a table is free, with the agent
      function `checkAvailability` (protocol v1.0);
    * `:ask_client` — also call the renderer function `clientInfo`, so
      the agent learns the user's time zone (protocol v1.0);
    * `:today` — the earliest date the form allows;
    * `:base_url` — where the agent serves the restaurant's picture; the
      header has no picture without it.
  """
  @spec booking(String.t(), map(), String.t(), keyword()) :: [map()]
  def booking(surface_id, restaurant, version, options \\ []) do
    v1? = version == "v1.0"
    today = Keyword.get_lazy(options, :today, &RestaurantAgent.today/0)

    availability =
      if v1? and options[:availability] do
        row(
          id: "free",
          align: "center",
          children: [
            icon(id: "freeIcon", name: "event"),
            text(
              id: "availability",
              weight: 1,
              accessibility: accessibility(live: "polite"),
              text:
                call(
                  "checkAvailability",
                  [
                    restaurant_id: restaurant["id"],
                    date: bind("/booking/date"),
                    party_size: bind("/booking/partySize")
                  ],
                  catalog_id: Catalogs.restaurant_id()
                )
            )
          ]
        )
      end

    picture =
      if base_url = options[:base_url] do
        image(
          id: "picture",
          url: "#{base_url}/images/#{restaurant["id"]}.svg",
          description: restaurant["dish"],
          fit: "cover",
          variant: "avatar"
        )
      end

    name_checks = [
      check(call("required", value: bind("/booking/name")), "Tell us your name."),
      check(call("length", value: bind("/booking/name"), min: 2), "At least two letters, please.")
    ]

    tree =
      column(
        id: "root",
        children:
          Enum.reject(
            [
              row(
                id: "header",
                align: "center",
                children:
                  Enum.reject(
                    [
                      picture,
                      column(
                        id: "heading",
                        weight: 1,
                        children: [
                          subtitle("title", "Book a table at #{restaurant["name"]}", version),
                          text(id: "about", text: restaurant["description"], variant: "caption")
                        ]
                      )
                    ],
                    &is_nil/1
                  )
              ),
              divider(id: "rule"),
              overline("details", "Your details", version),
              text_field(
                id: "name",
                label: "Your name",
                value: bind("/booking/name"),
                checks: name_checks
              ),
              text_field(
                id: "email",
                label: "Email",
                value: bind("/booking/email"),
                checks: [
                  check(
                    call("email", value: bind("/booking/email")),
                    "Enter a valid email address."
                  )
                ]
              ),
              overline("table", "Your table", version),
              date_time_input(
                id: "date",
                label: "When",
                value: bind("/booking/date"),
                enable_date: true,
                enable_time: true,
                min: bind("/booking/today")
              ),
              text(
                id: "zone",
                variant: "caption",
                text: call("formatString", value: "Times are in ${/booking/timeZone}.")
              ),
              slider(
                id: "party",
                label: "Party size",
                value: bind("/booking/partySize"),
                min: 1,
                max: 12
              ),
              choice_picker(
                id: "seating",
                label: "Seating",
                variant: "mutuallyExclusive",
                display_style: "chips",
                options: [
                  %{"label" => "Inside", "value" => "inside"},
                  %{"label" => "Terrace", "value" => "terrace"},
                  %{"label" => "At the bar", "value" => "bar"}
                ],
                value: bind("/booking/seating")
              ),
              availability,
              text_field(
                id: "notes",
                label: "Notes for the kitchen",
                value: bind("/booking/notes"),
                variant: "longText"
              ),
              row(
                id: "actions",
                justify: "spaceBetween",
                align: "center",
                children: [
                  text(
                    id: "guests",
                    text:
                      call("pluralize",
                        value: bind("/booking/partySize"),
                        one: "One guest",
                        other: call("formatString", value: "${/booking/partySize} guests")
                      )
                  ),
                  button(
                    id: "submit",
                    variant: "primary",
                    child: text(text: "Confirm booking"),
                    checks: [
                      check(
                        call("and",
                          values: [
                            call("required", value: bind("/booking/name")),
                            call("email", value: bind("/booking/email"))
                          ]
                        ),
                        "Fill in your name and email first."
                      )
                    ],
                    action: event("submit_booking", booking: bind("/booking"))
                  )
                ]
              )
            ],
            &is_nil/1
          )
      )

    data = %{
      "booking" => %{
        "restaurantId" => restaurant["id"],
        "restaurant" => restaurant["name"],
        "name" => "",
        "email" => "",
        "date" => "#{Date.to_iso8601(Date.add(today, 1))}T19:30",
        "today" => Date.to_iso8601(today),
        "timeZone" => "your time zone",
        "partySize" => 2,
        "seating" => ["inside"],
        "notes" => ""
      }
    }

    messages = surface(surface_id, tree, data, version, send_data_model: true)

    if v1? and options[:ask_client],
      do: messages ++ [client_info_call(surface_id)],
      else: messages
  end

  @doc """
  A `callRendererFunction` message asking the renderer for `clientInfo`.
  The call id names the surface, so the response alone says where the
  answer goes.
  """
  @spec client_info_call(String.t()) :: map()
  def client_info_call(surface_id) do
    %{
      "version" => "v1.0",
      "callRendererFunction" => %{
        "functionCallId" => "clientinfo:" <> surface_id,
        "surfaceId" => surface_id,
        "callFunction" => %{
          "@call" => "clientInfo",
          "catalogId" => Catalogs.restaurant_id(),
          "args" => %{}
        }
      }
    }
  end

  @doc """
  The confirmation that replaces the form of `surface_id` once the table
  is booked: when, then the party and where the details went.
  """
  @spec confirmation(String.t(), map(), String.t()) :: [map()]
  def confirmation(surface_id, booking, version) do
    tree =
      column(
        id: "root",
        align: "center",
        children: [
          icon(id: "booked", name: "check"),
          subtitle("title", "Table booked", version),
          text(
            id: "when",
            text:
              call("formatString",
                value:
                  "${/booking/name}, we expect you at ${/booking/restaurant} on " <>
                    "${formatDate(value: ${/booking/date}, format: 'EEEE, MMMM d')} at " <>
                    "${formatDate(value: ${/booking/date}, format: 'HH:mm')}."
              )
          ),
          card(
            id: "summary",
            child:
              column(
                children: [
                  row(
                    id: "partyRow",
                    align: "center",
                    children: [
                      icon(id: "partyIcon", name: "person"),
                      text(
                        id: "party",
                        text:
                          call("pluralize",
                            value: bind("/booking/partySize"),
                            one: "A table for one.",
                            other:
                              call("formatString", value: "A table for ${/booking/partySize}.")
                          )
                      )
                    ]
                  ),
                  row(
                    id: "mailRow",
                    align: "center",
                    children: [
                      icon(id: "mailIcon", name: "mail"),
                      text(
                        id: "mail",
                        text:
                          call("formatString", value: "The details went to ${/booking/email}.")
                      )
                    ]
                  )
                ]
              )
          ),
          button(id: "done", child: text(text: "Done"), action: event("done"))
        ]
      )

    [
      %{
        "updateComponents" => %{
          "surfaceId" => surface_id,
          "components" => flatten(tree, version: version)
        }
      },
      %{
        "updateDataModel" => %{
          "surfaceId" => surface_id,
          "path" => "/booking",
          "value" => booking
        }
      }
    ]
    |> Enum.map(&Map.put(&1, "version", version))
  end

  @doc "The message that takes a surface away."
  @spec delete(String.t(), String.t()) :: map()
  def delete(surface_id, version),
    do: %{"version" => version, "deleteSurface" => %{"surfaceId" => surface_id}}

  # v1.0 has no heading variants: a heading is Markdown in a Text. A
  # surface's title, the title of a part of it, and the label over a
  # group of fields.
  defp heading(text, "v1.0"), do: text(id: "title", text: "## " <> text)
  defp heading(text, _v09), do: text(id: "title", text: text, variant: "h3")

  defp subtitle(id, text, "v1.0"), do: text(id: id, text: "### " <> text)
  defp subtitle(id, text, _v09), do: text(id: id, text: text, variant: "h4")

  defp overline(id, text, "v1.0"), do: text(id: id, text: "##### " <> text)
  defp overline(id, text, _v09), do: text(id: id, text: text, variant: "h5")

  # v1.0 puts the components and the data in createSurface; v0.9
  # follows it with updateComponents and updateDataModel, and themes the
  # surface.
  defp surface(surface_id, tree, data, "v1.0", options) do
    [
      %{
        "version" => "v1.0",
        "createSurface" => %{
          "surfaceId" => surface_id,
          "catalogId" => Catalogs.basic("v1.0").catalog_id,
          "sendDataModel" => options[:send_data_model],
          "components" => flatten(tree, version: "v1.0"),
          "dataModel" => data
        }
      }
    ]
  end

  defp surface(surface_id, tree, data, version, options) do
    create = %{
      "surfaceId" => surface_id,
      "catalogId" => Catalogs.basic(version).catalog_id,
      "theme" => @theme,
      "sendDataModel" => options[:send_data_model]
    }

    [
      %{"createSurface" => create},
      %{
        "updateComponents" => %{
          "surfaceId" => surface_id,
          "components" => flatten(tree, version: version)
        }
      },
      %{"updateDataModel" => %{"surfaceId" => surface_id, "path" => "/", "value" => data}}
    ]
    |> Enum.map(&Map.put(&1, "version", version))
  end
end

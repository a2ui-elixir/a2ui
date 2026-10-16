defmodule RestaurantAgent.Restaurants do
  @moduledoc """
  The restaurants the agent knows, and the tables they have free.

  Each restaurant has a picture the agent serves itself
  (`GET /images/<id>.svg`), so the examples need no network.
  """

  @restaurants [
    %{
      "id" => "trattoria-roma",
      "name" => "Trattoria Roma",
      "cuisine" => "Italian",
      "rating" => 4.6,
      "reviews" => 412,
      "price" => "$$",
      "distance" => 0.8,
      "color" => "#c0392b",
      "description" => "Fresh pasta every morning and a wood-fired oven."
    },
    %{
      "id" => "osteria-del-ponte",
      "name" => "Osteria del Ponte",
      "cuisine" => "Italian",
      "rating" => 4.2,
      "reviews" => 198,
      "price" => "$$$",
      "distance" => 2.4,
      "color" => "#8e44ad",
      "description" => "Northern Italian classics by the river."
    },
    %{
      "id" => "pizzeria-napoli",
      "name" => "Pizzeria Napoli",
      "cuisine" => "Italian",
      "rating" => 4.8,
      "reviews" => 1033,
      "price" => "$",
      "distance" => 1.1,
      "color" => "#d35400",
      "description" => "Neapolitan pizza, ninety seconds in the oven."
    },
    %{
      "id" => "sakura",
      "name" => "Sakura",
      "cuisine" => "Japanese",
      "rating" => 4.7,
      "reviews" => 640,
      "price" => "$$$",
      "distance" => 1.9,
      "color" => "#e84393",
      "description" => "Omakase counter and a quiet garden."
    },
    %{
      "id" => "ramen-ya",
      "name" => "Ramen-ya",
      "cuisine" => "Japanese",
      "rating" => 4.4,
      "reviews" => 377,
      "price" => "$",
      "distance" => 0.5,
      "color" => "#2d3436",
      "description" => "Tonkotsu broth simmered for eighteen hours."
    },
    %{
      "id" => "la-cantina",
      "name" => "La Cantina",
      "cuisine" => "Mexican",
      "rating" => 4.3,
      "reviews" => 251,
      "price" => "$$",
      "distance" => 3.2,
      "color" => "#27ae60",
      "description" => "Tacos al pastor and forty kinds of mezcal."
    },
    %{
      "id" => "spice-route",
      "name" => "Spice Route",
      "cuisine" => "Indian",
      "rating" => 4.5,
      "reviews" => 529,
      "price" => "$$",
      "distance" => 1.4,
      "color" => "#f39c12",
      "description" => "Tandoor breads and slow-cooked curries."
    },
    %{
      "id" => "le-petit-bistro",
      "name" => "Le Petit Bistro",
      "cuisine" => "French",
      "rating" => 4.1,
      "reviews" => 143,
      "price" => "$$$",
      "distance" => 2.0,
      "color" => "#2980b9",
      "description" => "Steak frites and a short, honest wine list."
    }
  ]

  @cuisines @restaurants |> Enum.map(& &1["cuisine"]) |> Enum.uniq()

  @doc "Every restaurant."
  @spec all() :: [map()]
  def all, do: @restaurants

  @doc "The cuisines, in the order the restaurants list them."
  @spec cuisines() :: [String.t()]
  def cuisines, do: @cuisines

  @doc "The restaurant with `id`, or `nil`."
  @spec get(String.t()) :: map() | nil
  def get(id), do: Enum.find(@restaurants, &(&1["id"] == id))

  @doc """
  The restaurants a request asks for: those of the cuisines its text
  names, all of them when it names none, nearest first.
  """
  @spec search(String.t()) :: {String.t() | nil, [map()]}
  def search(text) do
    words = text |> String.downcase() |> String.split(~r/[^\p{L}]+/u, trim: true)
    cuisine = Enum.find(@cuisines, &(String.downcase(&1) in words))

    found =
      @restaurants
      |> Enum.filter(&(cuisine == nil or &1["cuisine"] == cuisine))
      |> Enum.sort_by(& &1["distance"])

    {cuisine, found}
  end

  @doc """
  Whether a restaurant has a table: what the agent function
  `checkAvailability` answers. Large parties and late Friday evenings are
  harder; the answer is deterministic.
  """
  @spec availability(String.t(), String.t(), number()) :: {:ok, String.t()} | {:error, String.t()}
  def availability(id, date, party_size) do
    with %{} = restaurant <- get(id) || {:error, "Unknown restaurant: #{id}"},
         {:ok, at} <- parse_date(date) do
      cond do
        party_size > 8 ->
          {:ok,
           "#{restaurant["name"]} seats at most 8 at one table. Call them for a group booking."}

        Date.day_of_week(at) == 5 and at.hour >= 19 ->
          {:ok, "Fully booked on Friday evening. 17:30 is still free."}

        true ->
          {:ok, "A table for #{party_size} is free at #{Calendar.strftime(at, "%H:%M")}."}
      end
    end
  end

  defp parse_date(date) when is_binary(date) do
    case NaiveDateTime.from_iso8601(date <> if(String.length(date) == 16, do: ":00", else: "")) do
      {:ok, at} ->
        {:ok, at}

      {:error, _reason} ->
        case Date.from_iso8601(date) do
          {:ok, day} -> {:ok, NaiveDateTime.new!(day, ~T[19:00:00])}
          {:error, _reason} -> {:error, "Not a date: #{date}"}
        end
    end
  end

  defp parse_date(other), do: {:error, "Not a date: #{inspect(other)}"}

  @doc "The picture of a restaurant: a plate in its color, with its initials."
  @spec image(String.t()) :: String.t() | nil
  def image(id) do
    with %{"name" => name, "color" => color} <- get(id) do
      initials = name |> String.split() |> Enum.map_join(&String.first/1) |> String.slice(0, 2)

      """
      <svg xmlns="http://www.w3.org/2000/svg" width="160" height="120" viewBox="0 0 160 120">
        <rect width="160" height="120" fill="#{color}"/>
        <circle cx="80" cy="60" r="42" fill="#fff" opacity="0.9"/>
        <circle cx="80" cy="60" r="30" fill="none" stroke="#{color}" stroke-width="3"/>
        <text x="80" y="70" font-family="sans-serif" font-size="26" font-weight="bold"
              text-anchor="middle" fill="#{color}">#{initials}</text>
      </svg>
      """
    end
  end
end

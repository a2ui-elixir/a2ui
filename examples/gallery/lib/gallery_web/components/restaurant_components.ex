defmodule GalleryWeb.RestaurantComponents do
  @moduledoc """
  The components of the restaurant catalog
  (`examples/catalogs/restaurant_catalog.json`), drawn by the gallery as
  a host draws its own catalog's components: with namespaced classes
  (`restaurant-*`) that `priv/static/assets/catalog.css` styles from the
  same `--a2ui-*` tokens as the basic components.
  """

  use Phoenix.Component

  @star "M10 1.9l2.47 5.01 5.53.8-4 3.9.94 5.5L10 14.5l-4.94 2.6.94-5.5-4-3.9 5.53-.8L10 1.9z"

  @doc "The function components by component type, for `A2UIPhoenix.Surface`."
  def components, do: %{"Rating" => &rating/1}

  @doc "`Rating`: stars out of `max` (halves included), and an optional label."
  def rating(assigns) do
    props = assigns.props
    out_of = if is_integer(props["max"]) and props["max"] > 0, do: props["max"], else: 5
    value = if is_number(props["value"]), do: props["value"] |> max(0) |> min(out_of), else: 0

    assigns =
      assign(assigns,
        max: out_of,
        value: value,
        stars: stars(value, out_of),
        clip: "#{assigns.attrs["id"] || "rating"}-half",
        star: @star
      )

    ~H"""
    <span
      class="restaurant-rating"
      role="img"
      aria-label={"#{@value} out of #{@max} stars"}
      {Map.delete(@attrs, "aria-label")}
    >
      <span class="restaurant-rating-stars" aria-hidden="true">
        <svg
          :for={kind <- @stars}
          class={["restaurant-rating-star", "restaurant-rating-star-" <> kind]}
          viewBox="0 0 20 20"
        >
          <defs :if={kind == "half"}>
            <clipPath id={@clip}><rect width="10" height="20" /></clipPath>
          </defs>
          <path d={@star} />
          <path
            :if={kind == "half"}
            class="restaurant-rating-half"
            d={@star}
            clip-path={"url(##{@clip})"}
          />
        </svg>
      </span>
      <span :if={@props["label"]} class="restaurant-rating-label">{@props["label"]}</span>
    </span>
    """
  end

  # Whole stars, a half for a fraction between a quarter and three quarters,
  # and empty ones up to `max`.
  defp stars(value, out_of) do
    rounded = Float.round(value * 2.0) / 2
    full = trunc(rounded)
    half = if rounded - full == 0.5, do: 1, else: 0

    List.duplicate("full", full) ++
      List.duplicate("half", half) ++ List.duplicate("empty", out_of - full - half)
  end
end

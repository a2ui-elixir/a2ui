defmodule GalleryWeb.RestaurantComponents do
  @moduledoc """
  The components of the restaurant catalog
  (`examples/catalogs/restaurant_catalog.json`), drawn by the gallery as
  a host draws its own catalog's components.
  """

  use Phoenix.Component

  @doc "The function components by component type, for `A2UIPhoenix.Surface`."
  def components, do: %{"Rating" => &rating/1}

  @doc "`Rating`: stars out of `max`, and an optional label."
  def rating(assigns) do
    max = assigns.props["max"] || 5
    value = if is_number(assigns.props["value"]), do: assigns.props["value"], else: 0
    full = value |> round() |> min(max) |> max(0)

    assigns = assign(assigns, max: max, value: value, full: full)

    ~H"""
    <span
      class="rating"
      role="img"
      aria-label={"#{@value} out of #{@max} stars"}
      {Map.delete(@attrs, "aria-label")}
    >
      <span class="stars" aria-hidden="true">
        {String.duplicate("★", @full)}<span class="empty">{String.duplicate("☆", @max - @full)}</span>
      </span>
      <span :if={@props["label"]} class="rating-label">{@props["label"]}</span>
    </span>
    """
  end
end

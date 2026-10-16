defmodule GalleryWeb.WidgetComponents do
  @moduledoc """
  The components of the gallery's own catalog
  (`priv/catalogs/widgets_catalog.json`): what a host writes for a
  catalog of its own.
  """

  use Phoenix.Component

  alias A2UIPhoenix.Components

  @doc "The function components by component type, for `A2UIPhoenix.Surface`."
  def components, do: %{"Badge" => &badge/1, "Progress" => &progress/1, "Panel" => &panel/1}

  @doc "`Badge`: a label with a tone."
  def badge(assigns) do
    tone =
      if assigns.props["tone"] in ~w(info success warning danger),
        do: assigns.props["tone"],
        else: "info"

    assigns = assign(assigns, :tone, tone)

    ~H"""
    <span class={["badge", "badge-" <> @tone]} {@attrs}>{@props["text"]}</span>
    """
  end

  @doc "`Progress`: a bar from 0 to 1."
  def progress(assigns) do
    value =
      if is_number(assigns.props["value"]),
        do: assigns.props["value"] |> max(0) |> min(1),
        else: 0

    assigns = assign(assigns, :percent, round(value * 100))

    ~H"""
    <div
      class="progress"
      role="progressbar"
      aria-valuemin="0"
      aria-valuemax="100"
      aria-valuenow={@percent}
      aria-label={@attrs["aria-label"] || @props["label"]}
      {Map.delete(@attrs, "aria-label")}
    >
      <div class="progress-bar" style={"width: #{@percent}%"}></div>
      <span class="progress-label">{@props["label"]} {@percent} %</span>
    </div>
    """
  end

  @doc "`Panel`: its children under a heading."
  def panel(assigns) do
    ~H"""
    <section class="panel" {@attrs}>
      <h3 :if={@props["title"]}>{@props["title"]}</h3>
      <div class="panel-body">
        <Components.child ctx={@ctx} child={@props["children"]} />
      </div>
    </section>
    """
  end
end

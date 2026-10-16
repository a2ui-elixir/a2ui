defmodule GalleryWeb.IndexLive do
  @moduledoc "The list of scenarios, and of the gallery's other pages."

  use GalleryWeb, :live_view

  @icons %{
    "components" => "grid",
    "forms" => "form",
    "data" => "braces",
    "surfaces" => "layers",
    "functions" => "function",
    "custom_catalog" => "puzzle",
    "streaming" => "stream",
    "mcp" => "plug",
    "errors" => "alert",
    "v09" => "history"
  }

  @shown_features 4

  @impl true
  def mount(_params, _session, socket),
    do: {:ok, assign(socket, scenarios: Gallery.Scenario.all(), page_title: "A2UI gallery")}

  defp icon_for(scenario), do: Map.get(@icons, scenario.id(), "window")

  defp number(index), do: index |> Integer.to_string() |> String.pad_leading(2, "0")

  defp features(scenario) do
    {shown, rest} = Enum.split(scenario.features(), @shown_features)
    if rest == [], do: shown, else: shown ++ ["+#{length(rest)}"]
  end

  @impl true
  def render(assigns) do
    ~H"""
    <.page_header>
      <:eyebrow>A2UI · rendered by A2UIPhoenix</:eyebrow>
      <:title>The A2UI gallery</:title>
      <p>
        Ten scripted agents talk A2UI to an <code>A2UIPhoenix</code>
        renderer, each showing a part of the protocol. Open one and use the surfaces: the
        inspector shows every message in both directions.
      </p>
      <:actions>
        <.link navigate="/chat" class="ui-button ui-button-secondary ui-button-md">
          <.icon name="chat" />Talk to the restaurant agent
        </.link>
        <.link navigate="/scenarios/components" class="ui-button ui-button-primary ui-button-md">
          Start with the components <.icon name="arrow-right" />
        </.link>
      </:actions>
    </.page_header>

    <h2 class="ui-section-title">Scenarios</h2>
    <div class="ui-grid" id="scenarios">
      <.link
        :for={{scenario, index} <- Enum.with_index(@scenarios, 1)}
        navigate={"/scenarios/" <> scenario.id()}
        class="ui-card"
      >
        <div class="ui-card-head">
          <span class="ui-card-icon"><.icon name={icon_for(scenario)} /></span>
          <span class="ui-card-number">{number(index)}</span>
        </div>
        <h3 class="ui-card-title">{scenario.title()}</h3>
        <p class="ui-card-text">{scenario.summary()}</p>
        <div class="ui-card-foot">
          <.tags items={features(scenario)} />
          <span class="ui-card-go"><.icon name="arrow-right" /></span>
        </div>
      </.link>
    </div>

    <h2 class="ui-section-title">More</h2>
    <div class="ui-grid">
      <.link navigate="/examples" class="ui-card">
        <div class="ui-card-head"><span class="ui-card-icon"><.icon name="book" /></span></div>
        <h3 class="ui-card-title">Reference examples</h3>
        <p class="ui-card-text">
          The A2UI project's own example surfaces, rendered here from the reference checkout.
        </p>
        <div class="ui-card-foot">
          <.tags items={["catalogs/basic/v1/examples"]} />
          <span class="ui-card-go"><.icon name="arrow-right" /></span>
        </div>
      </.link>
      <.link navigate="/chat" class="ui-card">
        <div class="ui-card-head"><span class="ui-card-icon"><.icon name="chat" /></span></div>
        <h3 class="ui-card-title">Restaurant agent</h3>
        <p class="ui-card-text">
          A conversation over A2A: streamed answers, actions, and function calls both ways.
        </p>
        <div class="ui-card-foot">
          <.tags items={["A2A", "examples/restaurant_agent"]} />
          <span class="ui-card-go"><.icon name="arrow-right" /></span>
        </div>
      </.link>
      <a href="/dashboard" class="ui-card">
        <div class="ui-card-head"><span class="ui-card-icon"><.icon name="gauge" /></span></div>
        <h3 class="ui-card-title">Dashboard</h3>
        <p class="ui-card-text">
          Phoenix LiveDashboard with the gallery's metrics: messages by direction, kind and page.
        </p>
        <div class="ui-card-foot">
          <.tags items={["LiveDashboard", "telemetry"]} />
          <span class="ui-card-go"><.icon name="arrow-right" /></span>
        </div>
      </a>
    </div>
    """
  end
end

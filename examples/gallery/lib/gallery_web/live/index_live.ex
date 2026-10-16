defmodule GalleryWeb.IndexLive do
  @moduledoc "The list of scenarios, and of the gallery's other pages."

  use GalleryWeb, :live_view

  @impl true
  def mount(_params, _session, socket),
    do: {:ok, assign(socket, scenarios: Gallery.Scenario.all(), page_title: "A2UI gallery")}

  @impl true
  def render(assigns) do
    ~H"""
    <h1>A2UI gallery</h1>
    <p class="lead">
      Each scenario is a scripted agent talking A2UI to an <code>A2UIPhoenix</code>
      renderer. Click around: the inspector shows every message
      in both directions.
    </p>
    <div class="cards">
      <.link :for={scenario <- @scenarios} navigate={"/scenarios/" <> scenario.id()} class="card">
        <h2>{scenario.title()}</h2>
        <p>{scenario.summary()}</p>
        <ul class="chips">
          <li :for={feature <- scenario.features()}>{feature}</li>
        </ul>
      </.link>
      <.link navigate="/examples" class="card">
        <h2>Reference examples</h2>
        <p>The A2UI project's own example surfaces, rendered here (needs the reference checkout).</p>
      </.link>
      <.link navigate="/chat" class="card">
        <h2>Restaurant agent</h2>
        <p>Chat with the restaurant agent over A2A: streaming answers, actions, function calls.</p>
      </.link>
    </div>
    """
  end
end

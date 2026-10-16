defmodule Gallery.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      GalleryWeb.Telemetry,
      {Phoenix.PubSub, name: Gallery.PubSub},
      GalleryWeb.Endpoint
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: Gallery.Supervisor)
  end

  @impl true
  def config_change(changed, _new, removed) do
    GalleryWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end

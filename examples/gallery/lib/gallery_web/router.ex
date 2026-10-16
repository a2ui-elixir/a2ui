defmodule GalleryWeb.Router do
  use GalleryWeb, :router

  import Phoenix.LiveDashboard.Router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {GalleryWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
  end

  scope "/", GalleryWeb do
    pipe_through :browser

    live "/", IndexLive
    live "/scenarios/:id", ScenarioLive
    live "/examples", ExamplesLive
    live "/examples/:name", ExamplesLive
    live "/chat", ChatLive
  end

  scope "/" do
    pipe_through :browser
    live_dashboard "/dashboard", metrics: GalleryWeb.Telemetry
  end
end

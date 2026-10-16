defmodule SiteWeb.Router do
  use SiteWeb, :router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :put_root_layout, html: {SiteWeb.Layouts, :root}
    plug :put_secure_browser_headers
  end

  scope "/", SiteWeb do
    pipe_through :browser

    get "/", PageController, :home
  end
end

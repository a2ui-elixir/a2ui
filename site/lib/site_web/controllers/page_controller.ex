defmodule SiteWeb.PageController do
  use SiteWeb, :controller

  def home(conn, _params), do: render(conn, :home)
end

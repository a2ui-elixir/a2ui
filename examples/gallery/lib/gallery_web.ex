defmodule GalleryWeb do
  @moduledoc """
  The web side of the gallery: `use GalleryWeb, :live_view` and friends.
  """

  def router do
    quote do
      use Phoenix.Router, helpers: false

      import Plug.Conn
      import Phoenix.Controller
      import Phoenix.LiveView.Router
    end
  end

  def live_view do
    quote do
      use Phoenix.LiveView

      import Phoenix.HTML
      import GalleryWeb.CoreComponents
      alias Phoenix.LiveView.JS
    end
  end

  def html do
    quote do
      use Phoenix.Component

      import Phoenix.HTML
      import GalleryWeb.CoreComponents
      alias Phoenix.LiveView.JS
    end
  end

  defmacro __using__(which) when is_atom(which), do: apply(__MODULE__, which, [])
end

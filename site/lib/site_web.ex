defmodule SiteWeb do
  @moduledoc """
  The web interface of the landing page: `use SiteWeb, :router`,
  `:controller` or `:html`.
  """

  def router do
    quote do
      use Phoenix.Router, helpers: false

      import Plug.Conn
      import Phoenix.Controller
    end
  end

  def controller do
    quote do
      use Phoenix.Controller, formats: [:html]

      import Plug.Conn
    end
  end

  def html do
    quote do
      use Phoenix.Component

      import SiteWeb.Components
    end
  end

  defmacro __using__(which) when is_atom(which), do: apply(__MODULE__, which, [])
end

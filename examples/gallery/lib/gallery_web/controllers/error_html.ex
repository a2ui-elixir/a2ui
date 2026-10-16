defmodule GalleryWeb.ErrorHTML do
  @moduledoc false

  def render(template, _assigns), do: Phoenix.Controller.status_message_from_template(template)
end

defmodule GalleryWeb.NotFoundError do
  @moduledoc "A page that does not exist, such as an unknown scenario: a 404."
  defexception message: "Not found", plug_status: 404
end

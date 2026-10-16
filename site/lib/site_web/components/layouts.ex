defmodule SiteWeb.Layouts do
  @moduledoc "The page shell (`layouts/root.html.heex`)."
  use SiteWeb, :html

  embed_templates "layouts/*"
end

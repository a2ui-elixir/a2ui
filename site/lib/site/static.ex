defmodule Site.Static do
  @moduledoc """
  The landing page as static files: `index.html` and the files under
  `priv/static`. The page links its assets by relative paths, so the
  directory can be served from any path, or opened from disk.
  """

  @doc "The landing page's HTML, as the endpoint serves it at `/`."
  def page do
    inner = Phoenix.Template.render(SiteWeb.PageHTML, "home", "html", %{})

    SiteWeb.Layouts
    |> Phoenix.Template.render_to_iodata("root", "html", %{inner_content: inner})
    |> IO.iodata_to_binary()
  end

  @doc """
  Writes the page and its assets into `dir`, created if needed, and returns
  the paths written, relative to `dir`.
  """
  def build(dir) do
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, "index.html"), page())

    static = Application.app_dir(:site, "priv/static")

    assets =
      static
      |> Path.join("**")
      |> Path.wildcard(match_dot: false)
      |> Enum.filter(&File.regular?/1)
      |> Enum.map(fn source ->
        relative = Path.relative_to(source, static)
        target = Path.join(dir, relative)
        File.mkdir_p!(Path.dirname(target))
        File.cp!(source, target)
        relative
      end)

    ["index.html" | Enum.sort(assets)]
  end
end

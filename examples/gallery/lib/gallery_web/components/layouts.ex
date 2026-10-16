defmodule GalleryWeb.Layouts do
  @moduledoc "The page layout: scripts, styles and navigation."

  use GalleryWeb, :html

  def root(assigns) do
    ~H"""
    <!DOCTYPE html>
    <html lang="en">
      <head>
        <meta charset="utf-8" />
        <meta name="viewport" content="width=device-width, initial-scale=1" />
        <meta name="csrf-token" content={Plug.CSRFProtection.get_csrf_token()} />
        <title>{assigns[:page_title] || "A2UI gallery"}</title>
        <link
          rel="stylesheet"
          href="https://fonts.googleapis.com/icon?family=Material+Icons"
        />
        <link rel="stylesheet" href="/a2ui_phoenix/a2ui_phoenix.css" />
        <link rel="stylesheet" href="/assets/gallery.css" />
        <script src="/js/phoenix.js">
        </script>
        <script src="/js/phoenix_live_view.js">
        </script>
        <script src="/a2ui_phoenix/a2ui_phoenix.js">
        </script>
        <script src="/assets/gallery.js">
        </script>
      </head>
      <body>
        <header class="topbar">
          <a href="/" class="brand">A2UI gallery</a>
          <nav>
            <a href="/">Scenarios</a>
            <a href="/examples">Reference examples</a>
            <a href="/chat">Restaurant agent</a>
            <a href="/dashboard">Dashboard</a>
          </nav>
        </header>
        <main class="page">
          {@inner_content}
        </main>
      </body>
    </html>
    """
  end
end

defmodule GalleryWeb.Layouts do
  @moduledoc "The page layout: the head, and the header with the gallery's pages and the theme switch."

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
        <link rel="icon" href="/assets/favicon.svg" type="image/svg+xml" />
        <script>
          (function () {
            var root = document.documentElement;
            try {
              var theme = localStorage.getItem("gallery-theme");
              if (theme === "light" || theme === "dark") root.setAttribute("data-theme", theme);
            } catch (error) {}
            var picked = root.getAttribute("data-theme");
            var dark = window.matchMedia("(prefers-color-scheme: dark)").matches;
            root.setAttribute("data-scheme", picked || (dark ? "dark" : "light"));
          })();
        </script>
        <link rel="preconnect" href="https://fonts.googleapis.com" />
        <link rel="preconnect" href="https://fonts.gstatic.com" crossorigin />
        <link
          rel="stylesheet"
          href="https://fonts.googleapis.com/css2?family=Material+Symbols+Outlined:opsz,wght,FILL,GRAD@20..48,100..700,0..1,-50..200&display=block"
        />
        <link rel="stylesheet" href="/a2ui_phoenix/a2ui_phoenix.css" />
        <link rel="stylesheet" href="/assets/catalog.css" />
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
        <header class="app-header">
          <a href="/" class="app-brand">
            <span class="app-brand-mark"><.icon name="logo" /></span>
            A2UI <span class="app-brand-tag">gallery</span>
          </a>
          <nav class="app-nav" aria-label="Pages">
            <a href="/"><.icon name="grid" /><span class="app-nav-label">Scenarios</span></a>
            <a href="/examples">
              <.icon name="book" /><span class="app-nav-label">Reference examples</span>
            </a>
            <a href="/chat">
              <.icon name="chat" /><span class="app-nav-label">Restaurant agent</span>
            </a>
            <a href="/dashboard">
              <.icon name="gauge" /><span class="app-nav-label">Dashboard</span>
            </a>
          </nav>
          <div class="app-actions">
            <button
              type="button"
              class="ui-icon-button theme-toggle"
              data-theme-toggle
              aria-label="Switch the theme"
            >
              <.icon name="moon" class="ui-icon theme-to-dark" />
              <.icon name="sun" class="ui-icon theme-to-light" />
            </button>
          </div>
        </header>
        <main class="app-main">
          {@inner_content}
        </main>
      </body>
    </html>
    """
  end
end

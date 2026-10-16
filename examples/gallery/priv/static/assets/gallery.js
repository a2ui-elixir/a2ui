// The gallery's page script: the theme switch, the current page in the
// header, and the LiveView socket with a2ui_phoenix's hooks (the McpApp
// bridge) and the gallery's own.
(function () {
  "use strict";

  var root = document.documentElement;
  var prefersDark = window.matchMedia("(prefers-color-scheme: dark)");

  // The theme: the visitor's pick, else the system's.
  function scheme() {
    var picked = root.getAttribute("data-theme");
    if (picked === "light" || picked === "dark") return picked;
    return prefersDark.matches ? "dark" : "light";
  }

  function syncScheme() {
    var current = scheme();
    root.setAttribute("data-scheme", current);
    document.querySelectorAll("[data-theme-toggle]").forEach(function (button) {
      button.setAttribute("aria-label", current === "dark" ? "Use the light theme" : "Use the dark theme");
    });
  }

  function markCurrentPage() {
    var path = window.location.pathname;
    document.querySelectorAll(".app-nav a").forEach(function (link) {
      var href = link.getAttribute("href");
      var current = href === "/" ? path === "/" || path.indexOf("/scenarios/") === 0 : path.indexOf(href) === 0;
      if (current) link.setAttribute("aria-current", "page");
      else link.removeAttribute("aria-current");
    });
  }

  if (prefersDark.addEventListener) prefersDark.addEventListener("change", syncScheme);
  window.addEventListener("phx:page-loading-stop", markCurrentPage);

  window.addEventListener("DOMContentLoaded", function () {
    syncScheme();
    markCurrentPage();

    document.querySelectorAll("[data-theme-toggle]").forEach(function (button) {
      button.addEventListener("click", function () {
        var next = scheme() === "dark" ? "light" : "dark";
        root.setAttribute("data-theme", next);
        try {
          localStorage.setItem("gallery-theme", next);
        } catch (error) {
          // Storage can be unavailable (private windows, blocked site data).
        }
        syncScheme();
      });
    });

    var csrfToken = document.querySelector("meta[name='csrf-token']").getAttribute("content");

    var hooks = Object.assign({}, window.A2UIPhoenix.hooks, {
      // Keeps a transcript scrolled to its newest line.
      ScrollToEnd: {
        mounted: function () {
          this.el.scrollTop = this.el.scrollHeight;
        },
        updated: function () {
          this.el.scrollTop = this.el.scrollHeight;
        }
      }
    });

    var liveSocket = new LiveView.LiveSocket("/live", Phoenix.Socket, {
      hooks: hooks,
      params: {_csrf_token: csrfToken}
    });

    liveSocket.connect();
    window.liveSocket = liveSocket;
  });
})();

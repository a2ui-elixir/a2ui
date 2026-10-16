// Connects the LiveView socket with a2ui_phoenix's hooks (the McpApp
// bridge) and the gallery's own.
window.addEventListener("DOMContentLoaded", function () {
  var csrfToken = document.querySelector("meta[name='csrf-token']").getAttribute("content");

  var hooks = Object.assign({}, window.A2UIPhoenix.hooks, {
    // Keeps a transcript scrolled to its newest line.
    ScrollToEnd: {
      mounted: function () { this.el.scrollTop = this.el.scrollHeight; },
      updated: function () { this.el.scrollTop = this.el.scrollHeight; }
    }
  });

  var liveSocket = new LiveView.LiveSocket("/live", Phoenix.Socket, {
    hooks: hooks,
    params: {_csrf_token: csrfToken}
  });

  liveSocket.connect();
  window.liveSocket = liveSocket;
});

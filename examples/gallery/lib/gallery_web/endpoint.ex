defmodule GalleryWeb.Endpoint do
  use Phoenix.Endpoint, otp_app: :gallery

  @session_options [
    store: :cookie,
    key: "_gallery_key",
    signing_salt: "a2ui-session",
    same_site: "Lax"
  ]

  socket "/live", Phoenix.LiveView.Socket,
    websocket: [connect_info: [session: @session_options]],
    longpoll: [connect_info: [session: @session_options]]

  # The gallery's own assets, Phoenix's JavaScript, and a2ui_phoenix's
  # assets: its stylesheet, its script (hooks and openUrl), and the
  # sandbox proxy page that McpApp frames load.
  plug Plug.Static, at: "/", from: :gallery, only: ~w(assets media)
  plug Plug.Static, at: "/js", from: {:phoenix, "priv/static"}, only: ["phoenix.js"]

  plug Plug.Static,
    at: "/js",
    from: {:phoenix_live_view, "priv/static"},
    only: ["phoenix_live_view.js"]

  plug Plug.Static,
    at: "/a2ui_phoenix",
    from: {:a2ui_phoenix, "priv/static"},
    only: ~w(a2ui_phoenix.js a2ui_phoenix.css a2ui_mcp_sandbox.html)

  if code_reloading? do
    plug Phoenix.CodeReloader
  end

  plug Phoenix.LiveDashboard.RequestLogger,
    param_key: "request_logger",
    cookie_key: "request_logger"

  plug Plug.RequestId
  plug Plug.Telemetry, event_prefix: [:phoenix, :endpoint]

  plug Plug.Parsers,
    parsers: [:urlencoded, :multipart, :json],
    pass: ["*/*"],
    json_decoder: Phoenix.json_library()

  plug Plug.MethodOverride
  plug Plug.Head
  plug Plug.Session, @session_options
  plug GalleryWeb.Router
end

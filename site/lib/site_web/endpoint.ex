defmodule SiteWeb.Endpoint do
  use Phoenix.Endpoint, otp_app: :site

  plug Plug.Static,
    at: "/",
    from: :site,
    gzip: false,
    only: ~w(assets favicon.svg robots.txt)

  if code_reloading? do
    plug Phoenix.CodeReloader
  end

  plug Plug.RequestId
  plug Plug.Telemetry, event_prefix: [:phoenix, :endpoint]
  plug Plug.Head
  plug SiteWeb.Router
end

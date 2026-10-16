import Config

config :site, SiteWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4040],
  code_reloader: true,
  debug_errors: true

config :phoenix, :plug_init_mode, :runtime

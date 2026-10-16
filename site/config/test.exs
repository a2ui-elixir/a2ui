import Config

config :site, SiteWeb.Endpoint, http: [ip: {127, 0, 0, 1}, port: 4041], server: false

config :logger, level: :warning
config :phoenix, :plug_init_mode, :runtime

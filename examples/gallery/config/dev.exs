import Config

config :gallery, GalleryWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4000],
  check_origin: false,
  debug_errors: true,
  code_reloader: true,
  secret_key_base: "dev-only-secret-key-base-for-the-a2ui-gallery-example-0123456789abcdef"

config :phoenix, :stacktrace_depth, 20
config :phoenix, :plug_init_mode, :runtime
config :phoenix_live_view, debug_heex_annotations: true

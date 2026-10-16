import Config

config :gallery, GalleryWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "test-only-secret-key-base-for-the-a2ui-gallery-example-0123456789abcdef",
  server: false

config :gallery, tick_ms: 50, delay_scale: 0.05, agent_timeout_ms: 400
config :restaurant_agent, server: false, chunk_delay_ms: 0, today: ~D[2026-10-16]
config :logger, level: :warning
config :phoenix, :plug_init_mode, :runtime

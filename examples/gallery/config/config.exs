import Config

config :gallery, GalleryWeb.Endpoint,
  adapter: Bandit.PhoenixAdapter,
  url: [host: "localhost"],
  render_errors: [formats: [html: GalleryWeb.ErrorHTML], layout: false],
  pubsub_server: Gallery.PubSub,
  live_view: [signing_salt: "a2ui-gallery"]

# The agent the chat page talks to (examples/restaurant_agent).
config :gallery, :agent_url, "http://127.0.0.1:4001"

config :phoenix, :json_library, Jason

config :logger, :default_formatter,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

import_config "#{config_env()}.exs"

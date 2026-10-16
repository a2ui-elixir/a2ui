import Config

# `server: false` keeps the HTTP server down (tests start their own);
# `chunk_delay_ms` paces the streamed answers like a model writing them.
config :restaurant_agent,
  server: true,
  port: 4001,
  public_url: "http://127.0.0.1:4001",
  chunk_delay_ms: 25

config :logger, :default_formatter, format: "$time [$level] $message\n"

if config_env() == :test do
  config :restaurant_agent, server: false, chunk_delay_ms: 0
  config :logger, level: :warning
end

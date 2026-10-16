import Config

config :logger, level: :warning

if config_env() == :test do
  config :restaurant_agent, server: false, chunk_delay_ms: 0
end

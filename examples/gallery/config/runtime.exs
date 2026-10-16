import Config

if port = System.get_env("PORT") do
  config :gallery, GalleryWeb.Endpoint, http: [ip: {127, 0, 0, 1}, port: String.to_integer(port)]
end

if url = System.get_env("AGENT_URL") do
  config :gallery, :agent_url, url
end

if config_env() != :test do
  config :gallery, GalleryWeb.Endpoint, server: true
end

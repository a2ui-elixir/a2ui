import Config

if port = System.get_env("PORT") do
  config :site, SiteWeb.Endpoint, http: [ip: {0, 0, 0, 0}, port: String.to_integer(port)]
end

if config_env() != :test do
  config :site, SiteWeb.Endpoint, server: true
end

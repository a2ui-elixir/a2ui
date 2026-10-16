import Config

port = System.get_env("PORT")

if port do
  config :restaurant_agent, port: String.to_integer(port)
end

cond do
  url = System.get_env("PUBLIC_URL") -> config :restaurant_agent, public_url: url
  port -> config :restaurant_agent, public_url: "http://127.0.0.1:#{port}"
  true -> :ok
end

defmodule RestaurantAgent.Application do
  @moduledoc false

  use Application

  require Logger

  @impl true
  def start(_type, _args) do
    children =
      if Application.get_env(:restaurant_agent, :server, true) do
        port = Application.fetch_env!(:restaurant_agent, :port)
        Logger.info("Restaurant finder agent on http://127.0.0.1:#{port}")
        [{Bandit, plug: RestaurantAgent.Router, ip: {127, 0, 0, 1}, port: port}]
      else
        []
      end

    Supervisor.start_link(children, strategy: :one_for_one, name: RestaurantAgent.Supervisor)
  end
end

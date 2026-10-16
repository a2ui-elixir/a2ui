defmodule RestaurantAgent do
  @moduledoc """
  A restaurant finder agent that answers with A2UI surfaces, served over
  every transport the A2UI project describes:

    * A2A (`/a2a`, and `/a2a/express` where the model writes Express),
      with the agent card at `/.well-known/agent-card.json`;
    * MCP (`/mcp`), as tools whose results embed A2UI messages;
    * AG-UI (`/agui`), as activity snapshots in a server-sent event run;
    * plain server-sent events (`/events`), one A2UI message per event.

  `RestaurantAgent.Turn` holds the conversation logic they share.
  """

  @doc "The URL the agent is reachable at, for links in its messages and card."
  @spec base_url() :: String.t()
  def base_url, do: Application.get_env(:restaurant_agent, :public_url, "http://127.0.0.1:4001")

  @doc """
  The day bookings start from: `config :restaurant_agent, today: ~D[...]`
  when set (the tests and the recorded replays fix it), today otherwise.
  """
  @spec today() :: Date.t()
  def today, do: Application.get_env(:restaurant_agent, :today) || Date.utc_today()
end

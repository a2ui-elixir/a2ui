defmodule RestaurantAgent.ExpressAgent do
  @moduledoc """
  The same agent, writing A2UI Express instead of direct JSON
  (`A2UIAgent.Express`). The A2A server reads an Express answer once it
  is complete, so `message/stream` sends it in one update at the end.

  Express has no notation for function responses, so the booking form
  of this endpoint does not ask the agent whether a table is free. It
  writes for the basic catalog alone (see
  `RestaurantAgent.Catalogs.generators/1`), so the stars are text.
  """

  @behaviour A2UIAgent.A2A.Agent

  alias RestaurantAgent.{Agent, Catalogs}

  @impl true
  def run(request), do: Agent.run(request, :express)

  @impl true
  def options, do: [generator: Catalogs.generators(format: A2UIAgent.Express)]

  @impl true
  def card,
    do:
      Agent.card(
        "/a2a/express",
        "Finds restaurants and books tables; the model writes A2UI Express.",
        catalogs: [Catalogs.basic("v1.0").catalog_id]
      )
end

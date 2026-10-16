defmodule RestaurantAgent.Test.Renderer do
  @moduledoc false
  # A renderer for the tests: an A2UIPhoenix.Session holding the basic and
  # restaurant catalogs, with the renderer function clientInfo, driven by
  # labels the way a user reads the screen.

  alias A2UICore.Catalog
  alias A2UICore.Resolution.{Binding, NodeResolver}
  alias A2UIPhoenix.Session

  @restaurant_path Path.expand("../../../catalogs/restaurant_catalog.json", __DIR__)

  def new do
    restaurant =
      @restaurant_path
      |> File.read!()
      |> Jason.decode!(objects: :ordered_objects)
      |> Catalog.from_json!()
      |> Catalog.put_implementations(%{
        "clientInfo" => fn _args, _context ->
          {:ok, %{"renderer" => "test", "locale" => "en-US", "timeZone" => "Europe/Berlin"}}
        end
      })

    Session.new([A2UICore.Catalog.Basic.catalog("v1.0"), restaurant],
      clock: fn -> ~U[2026-10-16 12:00:00Z] end
    )
  end

  # The metadata an A2A message from this renderer carries.
  def metadata(session) do
    {:ok, capabilities} =
      A2UICore.Processor.renderer_capabilities(session.processor, versions: ["v1.0"])

    {:ok, data_model} = Session.client_data_model(session)
    %{"a2uiRendererCapabilities" => capabilities, "a2uiRendererDataModel" => data_model}
  end

  # Applies agent messages; returns the session and the messages for the agent.
  def apply(session, messages) do
    {:ok, session, effects} = Session.handle_message(session, messages)
    {session, outbound(effects)}
  end

  def outbound(effects), do: for({:send, message} <- effects, do: message)

  def surface_ids(session), do: session |> Session.surfaces() |> Enum.map(& &1.id)

  def nodes(session, surface_id) do
    session
    |> Session.resolver(surface_id)
    |> NodeResolver.positions()
    |> Enum.sort_by(fn {position, _node} -> position end)
    |> Enum.map(&elem(&1, 1))
  end

  def texts(session, surface_id) do
    for node <- nodes(session, surface_id), node.type == "Text", do: value(node.props["text"])
  end

  def value(%Binding{value: value}), do: value
  def value(other), do: other

  # The Button whose label is `label`, the n-th one when several are.
  def click(session, surface_id, label, nth \\ 0) do
    resolver = Session.resolver(session, surface_id)

    buttons =
      for node <- nodes(session, surface_id),
          node.type == "Button",
          {:node, child} = node.props["child"],
          value(NodeResolver.node(resolver, child).props["text"]) == label,
          do: node

    {:ok, session, effects} =
      Session.invoke(session, surface_id, Enum.at(buttons, nth).ref, "action")

    {session, outbound(effects)}
  end

  def type(session, surface_id, label, value, property \\ "value") do
    node = Enum.find(nodes(session, surface_id), &(value(&1.props["label"]) == label))
    {:ok, session, effects} = Session.write(session, surface_id, node.ref, property, value)
    {session, outbound(effects)}
  end
end

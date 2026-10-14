defmodule A2UIPhoenix.Test.HostLive do
  @moduledoc false
  # A host LiveView as an application would write it: the session is an
  # assign managed by A2UIPhoenix.Live, each surface is a
  # A2UIPhoenix.Surface, and what the session sends or reports is
  # forwarded to the test process.
  #
  # LiveView session keys: "test" (the test pid), "messages" (agent
  # payloads applied in mount), "components" (extra component map, by
  # name of a function in A2UIPhoenix.Test.CustomComponents), "markdown"
  # (render body text through A2UIPhoenix.Test.CustomComponents.markdown/1),
  # "silent" (no callbacks).

  use Phoenix.LiveView

  alias A2UICore.Catalog.Basic
  alias A2UIPhoenix.{Live, Session}
  alias A2UIPhoenix.Test.CustomComponents

  @now ~U[2026-10-14 09:30:00Z]

  @doc false
  def now, do: @now

  @impl true
  def mount(_params, params, socket) do
    test = params["test"]
    session = Session.new([Basic.catalog("v1.0"), Basic.catalog("v0.9.1")], clock: &now/0)

    socket =
      socket
      |> Live.init(session, callbacks(test, params["silent"]))
      |> assign(
        test: test,
        components: CustomComponents.map(params["components"] || []),
        markdown: if(params["markdown"], do: &CustomComponents.markdown/1)
      )

    socket =
      Enum.reduce(params["messages"] || [], socket, fn payload, socket ->
        {_result, socket} = Live.handle_message(socket, payload)
        socket
      end)

    {:ok, socket}
  end

  defp callbacks(_test, true), do: []

  defp callbacks(test, _loud),
    do: [on_send: forward(test, :sent), on_effect: forward(test, :effect)]

  defp forward(test, tag) do
    fn value, socket ->
      if connected?(socket), do: send(test, {tag, value})
      socket
    end
  end

  @impl true
  def handle_info({:agent, payload}, socket) do
    {result, socket} = Live.handle_message(socket, payload)
    send(socket.assigns.test, {:handled, result})
    {:noreply, socket}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <main>
      <.live_component
        :for={surface <- Session.surfaces(@a2ui)}
        module={A2UIPhoenix.Surface}
        id={"surface-" <> surface.id}
        session={@a2ui}
        surface_id={surface.id}
        components={@components}
        markdown={@markdown}
      />
    </main>
    """
  end
end

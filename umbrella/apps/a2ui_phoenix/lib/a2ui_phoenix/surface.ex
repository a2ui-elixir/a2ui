defmodule A2UIPhoenix.Surface do
  @moduledoc """
  A LiveComponent that renders one surface of an `A2UIPhoenix.Session`.

      <.live_component
        module={A2UIPhoenix.Surface}
        id="surface-main"
        session={@a2ui}
        surface_id="main"
      />

  Assigns: `:id`, `:session` and `:surface_id` (required); `:components`
  — component functions by type, merged over
  `A2UIPhoenix.Components.Basic.components/0` and
  `A2UIPhoenix.Components.MCP.components/0`; `:markdown` and
  `:mcp_sandbox` — see `A2UIPhoenix.Context`.

  The component owns the surface's local UI state: the open tab, whether a
  modal is open, a choice filter. Input that concerns the agent is sent to
  the LiveView process, which owns the session:

    * `{A2UIPhoenix.Surface, surface_id, {:write, ref, property, value}}` —
      user input reached a two-way binding;
    * `{A2UIPhoenix.Surface, surface_id, {:invoke, ref, property}}` — the
      user triggered an action;
    * `{A2UIPhoenix.Surface, surface_id, {:mcp_app, ref, method, params, id}}`
      — an embedded MCP App sent a request (`id` is `nil` for a
      notification).

  `A2UIPhoenix.Live` handles both.
  """

  use Phoenix.LiveComponent

  alias A2UICore.Resolution.{Node, NodeResolver}
  alias A2UIPhoenix.{Components, Context, Inputs, Session}
  alias A2UIPhoenix.Components.{Basic, MCP}

  @moduledoc since: "0.1.0"

  @impl true
  def mount(socket), do: {:ok, assign(socket, ui: %{})}

  @impl true
  def update(assigns, socket) do
    session = assigns.session
    resolver = Session.resolver(session, assigns.surface_id)

    socket =
      socket
      |> assign(
        id: assigns.id,
        surface_id: assigns.surface_id,
        surface: Session.surface(session, assigns.surface_id),
        resolver: resolver,
        components:
          Basic.components()
          |> Map.merge(MCP.components())
          |> Map.merge(assigns[:components] || %{}),
        markdown: assigns[:markdown],
        mcp_sandbox: assigns[:mcp_sandbox],
        clock: session.clock
      )
      |> update(:ui, &prune(&1, resolver))
      |> put_context()

    {:ok, socket}
  end

  # Local state of nodes that are gone is dropped.
  defp prune(ui, nil), do: ui

  defp prune(ui, resolver),
    do: Map.filter(ui, fn {ref, _state} -> NodeResolver.node(resolver, ref) end)

  defp put_context(socket) do
    assigns = socket.assigns

    assign(socket, :ctx, %Context{
      surface_id: assigns.surface_id,
      surface: assigns.surface,
      resolver: assigns.resolver,
      target: assigns.myself,
      components: assigns.components,
      ui: assigns.ui,
      markdown: assigns.markdown,
      mcp_sandbox: assigns.mcp_sandbox
    })
  end

  @impl true
  def render(assigns) do
    assigns = assign(assigns, :root, assigns.resolver && NodeResolver.root(assigns.resolver))

    ~H"""
    <div id={@id} class="a2ui-surface" data-a2ui-surface={@surface_id}>
      <form
        :if={@root}
        id={"#{@id}-form"}
        phx-change="a2ui:input"
        phx-submit="a2ui:submit"
        phx-target={@myself}
        autocomplete="off"
      >
        <Components.component_node ctx={@ctx} ref={@root.ref} />
      </form>
    </div>
    """
  end

  @impl true
  def handle_event("a2ui:input", %{"_target" => ["a2ui", ref, field]} = params, socket) do
    case node(socket, ref) do
      %Node{} = node -> input(socket, node, field, get_in(params, ["a2ui", ref, field]))
      nil -> {:noreply, socket}
    end
  end

  def handle_event("a2ui:action", %{"ref" => ref, "property" => property}, socket) do
    case node(socket, ref) do
      %Node{} = node -> socket |> open_modals(node) |> notify({:invoke, node.ref, property})
      nil -> {:noreply, socket}
    end
  end

  def handle_event("a2ui:toggle", %{"ref" => ref, "option" => option}, socket) do
    case node(socket, ref) do
      %Node{} = node ->
        {:write, property, value} = Inputs.toggle(node, option)
        notify(socket, {:write, node.ref, property, value})

      nil ->
        {:noreply, socket}
    end
  end

  def handle_event("a2ui:tab", %{"ref" => ref, "index" => index}, socket) do
    with %Node{} = node <- node(socket, ref),
         {index, ""} <- Integer.parse(index) do
      {:noreply, put_ui(socket, node.ref, :tab, index)}
    else
      _invalid -> {:noreply, socket}
    end
  end

  def handle_event("a2ui:modal", %{"ref" => ref, "open" => open}, socket) do
    case node(socket, ref) do
      %Node{} = node -> {:noreply, put_ui(socket, node.ref, :open, open == "true")}
      nil -> {:noreply, socket}
    end
  end

  def handle_event("a2ui:mcp_app", %{"ref" => ref, "method" => method} = params, socket)
      when is_binary(method) do
    case node(socket, to_string(ref)) do
      %Node{type: "McpApp"} = node ->
        notify(socket, {:mcp_app, node.ref, method, params["params"], params["id"]})

      _other ->
        {:noreply, socket}
    end
  end

  def handle_event(_event, _params, socket), do: {:noreply, socket}

  defp input(socket, node, field, raw) do
    case Inputs.decode(node, field, raw, today(socket)) do
      {:write, property, value} -> notify(socket, {:write, node.ref, property, value})
      {:ui, key, value} -> {:noreply, put_ui(socket, node.ref, key, value)}
      :ignore -> {:noreply, socket}
    end
  end

  defp node(socket, ref) when is_binary(ref) do
    case Integer.parse(ref) do
      {ref, ""} -> Context.node(socket.assigns.ctx, ref)
      _invalid -> nil
    end
  end

  defp node(_socket, _ref), do: nil

  defp notify(socket, request) do
    send(self(), {__MODULE__, socket.assigns.surface_id, request})
    {:noreply, socket}
  end

  defp put_ui(socket, ref, key, value) do
    socket
    |> update(:ui, fn ui -> Map.update(ui, ref, %{key => value}, &Map.put(&1, key, value)) end)
    |> put_context()
  end

  # A trigger is clicked through when it holds the button: every modal
  # whose trigger contains the node opens.
  defp open_modals(socket, %Node{} = node) do
    resolver = socket.assigns.resolver

    node
    |> Stream.unfold(fn
      nil -> nil
      %Node{parent: parent} = current -> {current, parent && NodeResolver.node(resolver, parent)}
    end)
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.reduce(socket, fn [child, parent], socket ->
      if parent.type == "Modal" and parent.props["trigger"] == {:node, child.ref},
        do: put_ui(socket, parent.ref, :open, true),
        else: socket
    end)
  end

  defp today(%{assigns: %{clock: nil}}), do: Date.utc_today()
  defp today(%{assigns: %{clock: clock}}), do: DateTime.to_date(clock.())
end

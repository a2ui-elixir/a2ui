defmodule A2UIPhoenix.Components do
  @moduledoc """
  The function components that walk a resolved surface, and the helpers
  component implementations share.

  `component_node/1` renders one node of an `A2UICore.Resolution.NodeResolver`
  tree: a placeholder for the states that have no definition (`:pending`,
  `:unknown_type`, `:cyclic`), else the function component the context's
  component map has for the node's type. That component receives:

    * `@ctx` — the `A2UIPhoenix.Context`;
    * `@node` — the `A2UICore.Resolution.Node`;
    * `@props` — the node's props with every binding replaced by its
      current value (children stay `{:node, ref}`, actions stay
      `A2UICore.Resolution.Action`s);
    * `@a11y` — `A2UICore.Accessibility.attributes/2` of the component;
    * `@attrs` — the global attributes for the component's root element:
      its DOM id, `data-a2ui-id`, and the ARIA attributes the component
      declared (`aria-label` for an explicit label, `aria-description`,
      `aria-live` when not `"off"`, `aria-hidden` when hidden), and
      `aria-busy` while a property waits for an agent function.

  A component renders its children with `child/1` and its failed checks
  with `validation_errors/1`.
  """

  use Phoenix.Component

  alias A2UICore.Accessibility
  alias A2UICore.Resolution.{Binding, DataContext, Node}
  alias A2UICore.State.Components
  alias A2UIPhoenix.Context

  @moduledoc since: "0.1.0"

  @doc """
  Renders node `ref` of the context's tree (nothing when it is not
  mounted).
  """
  @spec component_node(map()) :: Phoenix.LiveView.Rendered.t()
  attr(:ctx, Context, required: true)
  attr(:ref, :integer, required: true)

  def component_node(assigns) do
    case Context.node(assigns.ctx, assigns.ref) do
      nil -> ~H""
      %Node{state: :resolved} = node -> resolved(assign(assigns, :node, node))
      %Node{} = node -> placeholder(assign(assigns, node: node, kind: node.state))
    end
  end

  defp resolved(%{ctx: ctx, node: node} = assigns) do
    case Map.get(ctx.components, node.type) do
      nil ->
        placeholder(assign(assigns, :kind, :unrendered))

      component ->
        component_assigns = component_assigns(ctx, node)
        assigns = assign(assigns, component: component, component_assigns: component_assigns)

        ~H"""
        {Phoenix.LiveView.TagEngine.component(
          @component,
          @component_assigns,
          {__MODULE__, __ENV__.function, __ENV__.file, __ENV__.line}
        )}
        """
    end
  end

  defp component_assigns(ctx, %Node{} = node) do
    {a11y, explicit_label?} = accessibility(ctx, node)

    %{
      ctx: ctx,
      node: node,
      props: props(node),
      a11y: a11y,
      attrs: %{
        "id" => Context.dom_id(ctx, node),
        "data-a2ui-id" => node.component_id,
        "aria-label" => if(explicit_label?, do: a11y.label),
        "aria-description" => a11y.description,
        "aria-live" => if(a11y.live != "off", do: a11y.live),
        "aria-hidden" => if(a11y.hidden, do: "true"),
        "aria-busy" => if(node.busy, do: "true")
      }
    }
  end

  defp accessibility(%Context{surface: surface}, %Node{} = node) do
    component = Components.get(surface.components, node.component_id)

    {a11y, _effects} =
      Accessibility.attributes(component, DataContext.for_surface(surface, path: node.data_path))

    explicit = component.props["accessibility"]
    {a11y, is_map(explicit) and explicit["label"] not in [nil, ""] and is_binary(a11y.label)}
  end

  @doc false
  @spec placeholder(map()) :: Phoenix.LiveView.Rendered.t()
  def placeholder(assigns) do
    ~H"""
    <div
      id={Context.dom_id(@ctx, @node)}
      class={["a2ui-placeholder", "a2ui-#{@kind}"]}
      data-a2ui-id={@node.component_id}
      data-a2ui-type={@node.type}
      aria-busy={if @kind == :pending, do: "true"}
    >
    </div>
    """
  end

  @doc """
  Renders a child slot: `{:node, ref}`, a list of them, or nothing.
  """
  @spec child(map()) :: Phoenix.LiveView.Rendered.t()
  attr(:ctx, Context, required: true)
  attr(:child, :any, required: true)

  def child(assigns) do
    ~H"""
    <%= case @child do %>
      <% {:node, ref} -> %>
        <.component_node ctx={@ctx} ref={ref} />
      <% children when is_list(children) -> %>
        <.component_node :for={{:node, ref} <- children} ctx={@ctx} ref={ref} />
      <% _none -> %>
    <% end %>
    """
  end

  @doc """
  Renders the messages of a component's failed checks (`isValid` false and
  `validationErrors`), each with the id `aria-describedby` points at.
  """
  @spec validation_errors(map()) :: Phoenix.LiveView.Rendered.t()
  attr(:ctx, Context, required: true)
  attr(:node, Node, required: true)
  attr(:props, :map, required: true)

  def validation_errors(assigns) do
    ~H"""
    <div
      :if={invalid?(@props)}
      :for={{message, index} <- Enum.with_index(@props["validationErrors"] || [])}
      id={Context.dom_id(@ctx, @node, "error-#{index}")}
      class="error a2ui-error-message"
    >
      {message}
    </div>
    """
  end

  @doc "Whether the component's checks fail."
  @spec invalid?(map()) :: boolean()
  def invalid?(props), do: props["isValid"] == false

  @doc """
  The ids of the error messages `validation_errors/1` renders, for an
  input's `aria-describedby` (`nil` when the checks pass).
  """
  @spec error_ids(Context.t(), Node.t(), map()) :: String.t() | nil
  def error_ids(ctx, node, props) do
    case {invalid?(props), props["validationErrors"] || []} do
      {true, [_ | _] = messages} ->
        Enum.map_join(0..(length(messages) - 1), " ", &Context.dom_id(ctx, node, "error-#{&1}"))

      _valid ->
        nil
    end
  end

  @doc """
  An inline style: the component's flex `weight` followed by `extra`
  declarations; `nil` when there is nothing to say.

      iex> A2UIPhoenix.Components.style(%{"weight" => 2}, ["text-align: center"])
      "flex: 2; text-align: center"
      iex> A2UIPhoenix.Components.style(%{})
      nil
  """
  @spec style(map(), [String.t() | nil]) :: String.t() | nil
  def style(props, extra \\ []) do
    weight = if is_number(props["weight"]), do: "flex: #{props["weight"]}"

    case Enum.reject([weight | extra], &is_nil/1) do
      [] -> nil
      declarations -> Enum.join(declarations, "; ")
    end
  end

  @doc """
  The node's props with every binding replaced by its value.
  """
  @spec props(Node.t()) :: map()
  def props(%Node{props: props}), do: unwrap(props)

  defp unwrap(%Binding{value: value}), do: value
  defp unwrap(%_{} = struct), do: struct
  defp unwrap(%{} = map), do: Map.new(map, fn {key, value} -> {key, unwrap(value)} end)
  defp unwrap(list) when is_list(list), do: Enum.map(list, &unwrap/1)
  defp unwrap(value), do: value

  @doc """
  Text for display: strings as they are, other scalars in their JSON
  spelling, `nil` as empty.

      iex> A2UIPhoenix.Components.text(3.5)
      "3.5"
      iex> A2UIPhoenix.Components.text(nil)
      ""
  """
  @spec text(term()) :: String.t()
  def text(nil), do: ""
  def text(value) when is_binary(value), do: value
  def text(value) when is_number(value) or is_boolean(value), do: to_string(value)
  def text(value), do: Jason.encode!(value)
end

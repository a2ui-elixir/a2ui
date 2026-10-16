defmodule A2UIPhoenix.Context do
  @moduledoc """
  What a component needs to render inside a surface.

    * `:surface_id`, `:surface` and `:resolver` — the surface and its
      resolved tree (`A2UICore.Resolution.NodeResolver`);
    * `:components` — the component map, `%{type => function_component}`;
    * `:target` — the `phx-target` of the surface's events (the
      `A2UIPhoenix.Surface` LiveComponent);
    * `:ui` — the surface's local UI state by node `ref` (the open tab, an
      open modal, a choice filter); never sent to the agent;
    * `:markdown` — an optional `(String.t() -> Phoenix.HTML.safe())`
      used for body text (`nil` renders text as is);
    * `:mcp_sandbox` — the URL of the MCP App sandbox proxy page (`nil`
      uses `A2UIPhoenix.Components.MCP.default_sandbox/0`).

  Custom components receive it as `@ctx` and use the helpers below to
  name their inputs and DOM ids the way the surface expects.
  """

  alias A2UICore.Resolution.{Node, NodeResolver}

  @moduledoc since: "0.1.0"

  defstruct surface_id: nil,
            surface: nil,
            resolver: nil,
            target: nil,
            components: %{},
            ui: %{},
            markdown: nil,
            mcp_sandbox: nil

  @type t :: %__MODULE__{
          surface_id: String.t() | nil,
          surface: A2UICore.State.Surface.t() | nil,
          resolver: NodeResolver.t() | nil,
          target: term(),
          components: %{optional(String.t()) => (map() -> Phoenix.LiveView.Rendered.t())},
          ui: %{optional(pos_integer()) => map()},
          markdown: (String.t() -> Phoenix.HTML.safe()) | nil,
          mcp_sandbox: String.t() | nil
        }

  @doc "The mounted node with `ref`, or `nil`."
  @spec node(t(), pos_integer()) :: Node.t() | nil
  def node(%__MODULE__{resolver: nil}, _ref), do: nil
  def node(%__MODULE__{resolver: resolver}, ref), do: NodeResolver.node(resolver, ref)

  @doc """
  A DOM id for `node`, unique on the page while the node is mounted;
  `suffix` names an element inside the component.

      iex> ctx = %A2UIPhoenix.Context{surface_id: "main form"}
      iex> A2UIPhoenix.Context.dom_id(ctx, 7, "input")
      "a2ui-main_form-7-input"
  """
  @spec dom_id(t(), Node.t() | pos_integer(), String.t() | nil) :: String.t()
  def dom_id(ctx, node, suffix \\ nil)
  def dom_id(ctx, %Node{ref: ref}, suffix), do: dom_id(ctx, ref, suffix)

  def dom_id(%__MODULE__{surface_id: surface_id}, ref, suffix) when is_integer(ref) do
    base = "a2ui-#{String.replace(surface_id || "surface", ~r/\s/u, "_")}-#{ref}"
    if suffix, do: "#{base}-#{suffix}", else: base
  end

  @doc """
  The form name of an input of `node`: `field` is the component property
  the input writes (`"value"` by default).

      iex> A2UIPhoenix.Context.input_name(7)
      "a2ui[7][value]"
  """
  @spec input_name(Node.t() | pos_integer(), String.t()) :: String.t()
  def input_name(node, field \\ "value")
  def input_name(%Node{ref: ref}, field), do: input_name(ref, field)
  def input_name(ref, field) when is_integer(ref), do: "a2ui[#{ref}][#{field}]"

  @doc "A value of the local UI state of `node`, or `default`."
  @spec ui(t(), Node.t(), atom(), term()) :: term()
  def ui(%__MODULE__{ui: ui}, %Node{ref: ref}, key, default),
    do: ui |> Map.get(ref, %{}) |> Map.get(key, default)
end

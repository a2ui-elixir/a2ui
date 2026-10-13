defmodule A2UICore.Resolution.Node do
  @moduledoc """
  One mounted position of a resolved component tree.

  A node is one component rendered in one data scope: a template
  component that is instantiated for three items is three nodes. Its
  `props` hold what a renderer needs:

    * `A2UICore.Resolution.Binding` for dynamic properties,
    * `A2UICore.Resolution.Action` for actions,
    * `{:node, ref}` for a child component (the child is
      `A2UICore.Resolution.NodeResolver.node/2` of that `ref`),
    * plain JSON for everything else.

  `state` says what the position holds:

    * `:resolved` — the component's definition is here and its type is in
      the catalog;
    * `:pending` — a parent refers to a component that has not arrived;
    * `:unknown_type` — the definition names a type the catalog lacks;
    * `:cyclic` — the component is referenced by one of its own
      descendants; the repeated reference is cut here.

  Placeholders (`:pending`, `:unknown_type`, `:cyclic`) have no props and
  no children.

  `ref` is the node's identity: it never changes while the position
  keeps the same component, and a node that is replaced (a placeholder
  that gets its definition, a component whose type changed) gets a new
  one. `instance_id` is a readable, deterministic name for the position.
  """

  @moduledoc since: "0.1.0"

  @enforce_keys [:ref, :instance_id, :component_id, :state, :data_path]
  defstruct [
    :ref,
    :instance_id,
    :component_id,
    :type,
    :state,
    :data_path,
    :parent,
    :edge,
    :catalog_id,
    occurrence: 1,
    props: %{},
    children: []
  ]

  @type state :: :resolved | :pending | :unknown_type | :cyclic

  @type t :: %__MODULE__{
          ref: pos_integer(),
          instance_id: String.t(),
          component_id: String.t(),
          type: String.t() | nil,
          state: state(),
          data_path: String.t(),
          parent: pos_integer() | nil,
          edge: String.t() | nil,
          catalog_id: String.t() | nil,
          occurrence: pos_integer(),
          props: map(),
          children: [pos_integer()]
        }

  @doc "True for the states that hold no definition of their own."
  @spec placeholder?(t()) :: boolean()
  def placeholder?(%__MODULE__{state: state}), do: state != :resolved
end

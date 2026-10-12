defmodule A2UICore.State.Component do
  @moduledoc """
  One component instance on a surface: its id, catalog type, and
  properties.

  The wire form is a flat object — `{"id": "title", "component": "Text",
  "text": "Hello"}`. A `Component` splits that into `id`, `type` and
  `props` (everything else), and `tree/1` puts it back together.

  A component optionally records the `catalog_id` it was created
  against, so a surface holding components from several catalogs can
  look up each one's schema and child-reference spec.

  Child references are derived from a `A2UICore.Catalog.RefSpec`, which
  the catalog supplies for the component's type (see
  `child_references/2`).

      iex> alias A2UICore.State.Component
      iex> component = Component.from_wire(%{"id" => "c", "component" => "Card", "child" => "t"})
      iex> {component.id, component.type, component.props}
      {"c", "Card", %{"child" => "t"}}
      iex> Component.tree(component)
      %{"id" => "c", "component" => "Card", "child" => "t"}
  """

  alias A2UICore.Catalog.RefSpec

  @moduledoc since: "0.1.0"

  @enforce_keys [:id, :type]
  defstruct [:id, :type, props: %{}, catalog_id: nil]

  @type t :: %__MODULE__{
          id: String.t(),
          type: String.t(),
          props: map(),
          catalog_id: String.t() | nil
        }

  @typedoc """
  What a catalog knows about a component type: the child-reference spec
  and the composition constraints (`nil` or `[]` means unconstrained).
  """
  @type info :: %{
          optional(:ref_spec) => RefSpec.t() | nil,
          optional(:allowed_parents) => [String.t()] | nil,
          optional(:allowed_children) => [String.t()] | nil
        }

  @doc "Builds a component from its parts."
  @spec new(String.t(), String.t(), map(), keyword()) :: t()
  def new(id, type, props \\ %{}, options \\ []) do
    %__MODULE__{id: id, type: type, props: props, catalog_id: options[:catalog_id]}
  end

  @doc """
  Builds a component from a wire object (`id`, `component`, and the
  properties).
  """
  @spec from_wire(map(), keyword()) :: t()
  def from_wire(%{"id" => id, "component" => type} = wire, options \\ []) do
    new(id, type, Map.drop(wire, ["id", "component"]), options)
  end

  @doc "The wire object: the properties plus `id` and `component`."
  @spec tree(t()) :: map()
  def tree(%__MODULE__{id: id, type: type, props: props}),
    do: Map.merge(props, %{"id" => id, "component" => type})

  @doc """
  The `{child_id, property_path}` pairs this component references,
  according to `spec` (`nil` means the component type is unknown to the
  catalog, so it has no known references).
  """
  @spec child_references(t(), RefSpec.t() | nil) :: [RefSpec.child_ref()]
  def child_references(%__MODULE__{}, nil), do: []

  def child_references(%__MODULE__{props: props}, %RefSpec{} = spec),
    do: RefSpec.extract(spec, props)
end

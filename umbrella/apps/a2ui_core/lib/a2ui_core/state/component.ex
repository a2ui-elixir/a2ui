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
  `child_references/3`).

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

  @single_ref_keys ~w(child contentChild entryPointChild componentId)
  @list_ref_keys ~w(children explicitList template tabs)
  @plain_keys ~w(text title label description icon url path value key id component type
                 variant size color action style styles theme weight align distribution
                 disabled selected)

  @doc """
  The `{child_id, property_path}` pairs this component references.

  A catalog's `spec` is authoritative when it names child properties.
  Without one (an unknown type, or a schema with no `ComponentId` /
  `ChildList` references) the references are inferred from property
  names and shapes: `child`, `children`, `*Child`, values holding a
  `componentId` / `child` key, and — when `known_ids` is given — strings
  naming a component on the surface.
  """
  @spec child_references(t(), RefSpec.t() | nil, Enumerable.t() | nil) :: [RefSpec.child_ref()]
  def child_references(component, spec, known_ids \\ nil)

  def child_references(%__MODULE__{props: props}, %RefSpec{} = spec, known_ids) do
    if RefSpec.empty?(spec),
      do: inferred_references(props, known_ids),
      else: RefSpec.extract(spec, props)
  end

  def child_references(%__MODULE__{props: props}, nil, known_ids),
    do: inferred_references(props, known_ids)

  defp inferred_references(props, known_ids) do
    known = if known_ids, do: MapSet.new(known_ids)

    for {key, value} <- Enum.sort_by(props, &elem(&1, 0)),
        key not in ["id", "component"],
        child_property?(key, value, known),
        {ref, sub_path} <- RefSpec.from_value(value) do
      {ref, if(sub_path == "", do: key, else: key <> "." <> sub_path)}
    end
  end

  defp child_property?(key, value, known) do
    cond do
      String.downcase(key) in @plain_keys -> false
      naming_convention?(key) -> true
      true -> holds_reference?(value, known)
    end
  end

  defp naming_convention?(key) do
    key in @single_ref_keys or key in @list_ref_keys or String.ends_with?(key, "Child") or
      String.ends_with?(key, "children") or String.starts_with?(key, "child")
  end

  defp holds_reference?(value, known) when is_list(value),
    do:
      Enum.any?(value, fn item ->
        (is_binary(item) and known != nil and MapSet.member?(known, item)) or
          (is_map(item) and (Map.has_key?(item, "child") or Map.has_key?(item, "componentId")))
      end)

  defp holds_reference?(value, _known) when is_map(value),
    do: Map.has_key?(value, "child") or Map.has_key?(value, "componentId")

  defp holds_reference?(value, known) when is_binary(value),
    do: known != nil and MapSet.member?(known, value)

  defp holds_reference?(_value, _known), do: false
end

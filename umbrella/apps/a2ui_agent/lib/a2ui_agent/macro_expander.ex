defmodule A2UIAgent.MacroExpander do
  @moduledoc """
  Puts macros (`A2UIAgent.Macro`) in front of a catalog: the model sees
  a catalog with the macros as components, and the renderer gets the
  base catalog's components they expand to.

      expander = A2UIAgent.MacroExpander.new(basic_catalog, [status_badge])

      # For the prompt: the base catalog with the macros added.
      {:ok, inference_catalog} = A2UIAgent.MacroExpander.inference_catalog(expander)

      # For the renderer: the model's messages with the macros expanded.
      {:ok, messages} = A2UIAgent.MacroExpander.to_transport(expander, model_messages)

  A macro component the model writes, `{"id": "badge", "component":
  "StatusBadge", ...}` (or with its arguments under `"parameters"`), is
  replaced by its macro's tree, flattened with the macro component's id
  as the root id (`A2UIAgent.Builder.flatten/2`) and checked against the
  base catalog. Components the expansion makes may be macros
  themselves; they are expanded in turn, up to a depth of 16.

  A macro that fails (an argument it cannot take, a component the
  catalog rejects) leaves its component as it was, and the failure is
  logged. Expansion deeper than the limit fails the whole call.

  Option `:passthrough_components` limits the base catalog's components
  the model sees: `nil` (the default) keeps them all, a list keeps the
  ones named, and `[]` leaves only the macros.
  """

  require Logger

  alias A2UIAgent.{Builder, Macro}
  alias A2UICore.{Catalog, Error, KeyOrder}

  @moduledoc since: "0.1.0"

  @enforce_keys [:catalog]
  defstruct [:catalog, :passthrough, macros: [], table: %{}]

  @type t :: %__MODULE__{
          catalog: Catalog.t(),
          passthrough: MapSet.t(String.t()) | nil,
          macros: [Macro.t()],
          table: %{optional(String.t()) => Macro.t()}
        }

  @max_depth 16
  @envelopes ["createSurface", "updateComponents"]
  @macro_catalog_id "https://a2ui.org/catalogs/macros"

  @doc """
  An expander for `macros` over the base catalog. Option:
  `:passthrough_components`.

  Raises `ArgumentError` when two macros have the same name.
  """
  @spec new(Catalog.t(), [Macro.t()], keyword()) :: t()
  def new(%Catalog{} = catalog, macros, options \\ []) when is_list(macros) do
    table = Map.new(macros, &{&1.name, &1})

    if map_size(table) != length(macros),
      do: raise(ArgumentError, "macro names must be unique")

    passthrough =
      case options[:passthrough_components] do
        nil -> nil
        names -> MapSet.new(names)
      end

    %__MODULE__{catalog: catalog, macros: macros, table: table, passthrough: passthrough}
  end

  @doc """
  The catalog the model writes for: the base catalog's components (those
  `:passthrough_components` keeps) and the macros, which are also added
  to its `anyComponent` union. Same id and protocol version as the base
  catalog.

  Fails with a `:catalog` error when a macro has the name of a base
  component.
  """
  @spec inference_catalog(t()) :: {:ok, Catalog.t()} | {:error, Error.t()}
  def inference_catalog(%__MODULE__{catalog: base} = expander) do
    document = Catalog.to_json(base, ordered: true)
    components = KeyOrder.get(document, "components") || KeyOrder.new()
    pruned = pruned_names(expander, components)

    components = Enum.reduce(pruned, components, &KeyOrder.delete(&2, &1))
    refs = Enum.reject(union_refs(document) || [], &names_any?(&1, pruned))

    case Enum.find(expander.macros, &KeyOrder.has_key?(components, &1.name)) do
      nil ->
        document
        |> KeyOrder.put("components", Enum.reduce(expander.macros, components, &put_macro/2))
        |> put_union_refs(Enum.reduce(expander.macros, refs, &add_ref/2))
        |> Catalog.from_json(catalog_id: base.catalog_id, protocol_version: base.protocol_version)

      macro ->
        {:error,
         Error.new(
           :catalog,
           "CATALOG_ERROR",
           "Macro component '#{macro.name}' collides with an existing component in the base catalog."
         )}
    end
  end

  defp put_macro(macro, components),
    do: KeyOrder.put(components, macro.name, Macro.ordered_json_schema(macro))

  defp add_ref(macro, refs) do
    ref = KeyOrder.new([{"$ref", "#/components/#{macro.name}"}])
    if Enum.any?(refs, &(ref_target(&1) == ref_target(ref))), do: refs, else: refs ++ [ref]
  end

  defp pruned_names(%{passthrough: nil}, _components), do: []

  defp pruned_names(%{passthrough: kept}, components),
    do: components |> Enum.map(&elem(&1, 0)) |> Enum.reject(&MapSet.member?(kept, &1))

  # The `oneOf` list of the document's `anyComponent`, or nil when it
  # has none: such a document admits all its components.
  defp union_refs(document) do
    case document
         |> KeyOrder.get("$defs")
         |> KeyOrder.get("anyComponent")
         |> KeyOrder.get("oneOf") do
      refs when is_list(refs) -> refs
      _none -> nil
    end
  end

  defp put_union_refs(document, refs) do
    case union_refs(document) do
      nil ->
        document

      _refs ->
        defs = KeyOrder.get(document, "$defs")
        union = defs |> KeyOrder.get("anyComponent") |> KeyOrder.put("oneOf", refs)
        KeyOrder.put(document, "$defs", KeyOrder.put(defs, "anyComponent", union))
    end
  end

  defp ref_target(ref), do: KeyOrder.get(ref, "$ref")

  defp names_any?(ref, names) do
    target = ref_target(ref)
    is_binary(target) and Enum.any?(names, &String.ends_with?(target, "/" <> &1))
  end

  @doc """
  A catalog of the macros alone, under the id
  `#{@macro_catalog_id}`, in the base catalog's protocol version.
  """
  @spec macro_catalog(t()) :: Catalog.t()
  def macro_catalog(%__MODULE__{catalog: base, macros: macros}) do
    components = KeyOrder.new(Enum.map(macros, &{&1.name, Macro.ordered_json_schema(&1)}))
    refs = Enum.map(macros, &KeyOrder.new([{"$ref", "#/components/#{&1.name}"}]))

    KeyOrder.new([
      {"$schema", "https://json-schema.org/draft/2020-12/schema"},
      {"catalogId", @macro_catalog_id},
      {"title", "A2UI Macros Catalog"},
      {"description", "Standalone catalog of high-level A2UI macro components."},
      {"components", components},
      {"$defs", KeyOrder.new([{"anyComponent", KeyOrder.new([{"oneOf", refs}])}])}
    ])
    |> Catalog.from_json!(catalog_id: @macro_catalog_id, protocol_version: base.protocol_version)
  end

  @doc """
  The model's messages with every macro component expanded (in the
  components of `createSurface` and `updateComponents` messages).
  Bindings and function calls are written for each message's
  `version`.

  Fails with a `:recursion` error when expansion goes deeper than
  #{@max_depth}.
  """
  @spec to_transport(t(), [map()]) :: {:ok, [map()]} | {:error, Error.t()}
  def to_transport(%__MODULE__{macros: []}, messages), do: {:ok, messages}

  def to_transport(%__MODULE__{} = expander, messages) when is_list(messages) do
    {:ok, Enum.map(messages, &lower(expander, KeyOrder.to_plain(&1)))}
  rescue
    # Expansion keeps the component of a macro that fails; only going
    # too deep gets here.
    error in Error -> {:error, error}
  end

  @doc "Messages going the other way, which need no change: returns them as they are."
  @spec to_inference(t(), [map()]) :: [map()]
  def to_inference(%__MODULE__{}, messages) when is_list(messages), do: messages

  defp lower(expander, message) do
    version = message["version"] || expander.catalog.protocol_version

    Enum.reduce(@envelopes, message, fn key, message ->
      case message do
        %{^key => %{"components" => [_ | _] = components} = body} ->
          Map.put(
            message,
            key,
            Map.put(body, "components", expand(expander, components, version, 0))
          )

        _other ->
          message
      end
    end)
  end

  defp expand(_expander, _components, _version, depth) when depth > @max_depth do
    raise Error.new(
            :recursion,
            "RECURSION_LIMIT",
            "Macro expansion exceeded maximum recursion depth of #{@max_depth}."
          )
  end

  defp expand(expander, components, version, depth) do
    Enum.flat_map(components, fn component ->
      case macro_of(expander, component) do
        nil -> [component]
        macro -> expand_one(expander, macro, component, version, depth)
      end
    end)
  end

  defp macro_of(expander, %{"component" => name}) when is_binary(name),
    do: Map.get(expander.table, name)

  defp macro_of(_expander, _component), do: nil

  defp expand_one(expander, macro, component, version, depth) do
    arguments =
      case component do
        %{"parameters" => %{} = parameters} -> parameters
        _inline -> Map.drop(component, ["component", "id"])
      end

    tree = Macro.call(macro, arguments)

    expanded =
      Builder.flatten(tree,
        root_id: component["id"],
        catalog: expander.catalog,
        version: version,
        macros: expander.table
      )

    expand(expander, expanded, version, depth + 1)
  rescue
    error ->
      if match?(%Error{category: :recursion}, error),
        do: reraise(error, __STACKTRACE__),
        else: keep(component, macro, error)
  end

  defp keep(component, macro, error) do
    Logger.error("Failed to expand macro #{inspect(macro.name)}: #{Exception.message(error)}")
    [component]
  end
end

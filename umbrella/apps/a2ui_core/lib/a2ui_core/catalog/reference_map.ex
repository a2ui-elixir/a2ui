defmodule A2UICore.Catalog.ReferenceMap do
  @moduledoc """
  Derives, from a catalog's component schemas, which properties are
  child references — the data `A2UICore.Catalog.RefSpec` extracts from.

  The analysis is a port of the reference `analyze_child_ref_schema` for
  JSON Schema components. A property is a **single** child reference
  when its schema is (or `allOf`/`anyOf`/`oneOf`-combines) a `$ref` to
  `ComponentId` or `Child`; a **list** when it refs `ChildList`, carries
  `explicitList`/`template` properties, or looks like a `componentId` +
  `path` template. An array whose items are child references is a list,
  and an array of objects with child-reference properties is a list
  with `nested` item keys (`tabs[].child`).

  Local `#/…` references are followed through the component's own
  `$defs` and the enclosing catalog document, with cycle protection.
  References to other documents (`common_types.json#/…`) are recognised
  by name only and not followed.
  """

  alias A2UICore.Catalog.RefSpec

  @moduledoc since: "0.1.0"

  @doc """
  Builds `%{component_name => RefSpec}` for every component of a catalog
  document (`%{"components" => %{name => schema}, "$defs" => …}`).
  """
  @spec build(map()) :: %{optional(String.t()) => RefSpec.t()}
  def build(%{"components" => components} = catalog) when is_map(components) do
    Map.new(components, fn {name, schema} -> {name, analyze(schema, catalog)} end)
  end

  def build(_catalog), do: %{}

  @doc """
  Analyses one component schema. `catalog` is the enclosing catalog
  document used to resolve `#/…` references that leave the component.
  """
  @spec analyze(term(), map() | nil) :: RefSpec.t()
  def analyze(schema, catalog \\ nil)

  def analyze(schema, catalog) when is_map(schema) do
    state = %{single: MapSet.new(), list: MapSet.new(), nested: %{}}
    ctx = %{root: schema, catalog: catalog, expanding: []}
    state = inspect_schema(schema, ctx, state)

    %RefSpec{single: state.single, list: state.list, nested: state.nested}
  end

  def analyze(_schema, _catalog), do: %RefSpec{}

  # -- schema walk --------------------------------------------------------------

  defp inspect_schema(schema, ctx, state) when is_map(schema) do
    state
    |> inspect_combinators(schema, ctx)
    |> inspect_ref(schema, ctx)
    |> inspect_properties(schema, ctx)
  end

  defp inspect_schema(_other, _ctx, state), do: state

  defp inspect_combinators(state, schema, ctx) do
    Enum.reduce(["allOf", "anyOf", "oneOf"], state, fn combinator, state ->
      case schema do
        %{^combinator => branches} when is_list(branches) ->
          Enum.reduce(branches, state, &inspect_schema(&1, ctx, &2))

        _ ->
          state
      end
    end)
  end

  defp inspect_ref(state, %{"$ref" => ref}, ctx) do
    with false <- ref in ctx.expanding,
         resolved when is_map(resolved) and map_size(resolved) > 0 <-
           resolve_ref(ref, ctx.root, ctx.catalog) do
      inspect_schema(resolved, %{ctx | expanding: [ref | ctx.expanding]}, state)
    else
      _ -> state
    end
  end

  defp inspect_ref(state, _schema, _ctx), do: state

  defp inspect_properties(state, %{"properties" => properties}, ctx) when is_map(properties) do
    properties
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.reduce(state, fn {name, schema}, state ->
      inspect_property(name, schema, ctx, state)
    end)
  end

  defp inspect_properties(state, _schema, _ctx), do: state

  defp inspect_property(name, _schema, _ctx, state) when name in ["id", "component"], do: state

  defp inspect_property(name, schema, ctx, state) do
    cond do
      single_child?(schema) ->
        %{state | single: MapSet.put(state.single, name)}

      child_list?(schema) ->
        %{state | list: MapSet.put(state.list, name)}

      true ->
        inspect_array_property(name, deref(schema, ctx), ctx, state)
    end
  end

  # An array property: items that are child references make a list;
  # items that are objects with child-reference properties make a list
  # with nested item keys.
  defp inspect_array_property(name, target, ctx, state) when is_map(target) do
    if target["type"] == "array" or Map.has_key?(target, "items") do
      case target["items"] do
        items when is_map(items) ->
          inspect_items(name, deref(items, ctx), state)

        _ ->
          state
      end
    else
      state
    end
  end

  defp inspect_array_property(_name, _target, _ctx, state), do: state

  defp inspect_items(name, items, state) do
    cond do
      single_child?(items) or child_list?(items) ->
        %{state | list: MapSet.put(state.list, name)}

      is_map(items["properties"]) ->
        items["properties"]
        |> Enum.filter(fn {_key, schema} -> single_child?(schema) or child_list?(schema) end)
        |> Enum.reduce(state, fn {key, _schema}, state ->
          %{
            state
            | list: MapSet.put(state.list, name),
              nested: Map.update(state.nested, name, MapSet.new([key]), &MapSet.put(&1, key))
          }
        end)

      true ->
        state
    end
  end

  defp deref(%{"$ref" => ref} = schema, ctx) do
    case resolve_ref(ref, ctx.root, ctx.catalog) do
      resolved when is_map(resolved) and map_size(resolved) > 0 -> resolved
      _ -> schema
    end
  end

  defp deref(schema, _ctx), do: schema

  # -- classification --------------------------------------------------------------

  @combinators ["allOf", "oneOf", "anyOf"]

  defp single_child?(%{} = schema) do
    ref_ends_with?(schema, ["/ComponentId", "/Child"]) or
      Enum.any?(@combinators, fn key ->
        is_list(schema[key]) and Enum.any?(schema[key], &single_child?/1)
      end)
  end

  defp single_child?(_other), do: false

  defp child_list?(%{} = schema) do
    ref_ends_with?(schema, ["/ChildList"]) or
      Enum.any?(@combinators, fn key ->
        is_list(schema[key]) and Enum.any?(schema[key], &child_list?/1)
      end) or template_properties?(schema["properties"])
  end

  defp child_list?(_other), do: false

  defp template_properties?(properties) when is_map(properties) do
    Map.has_key?(properties, "explicitList") or Map.has_key?(properties, "template") or
      (Map.has_key?(properties, "componentId") and
         (Map.has_key?(properties, "path") or Map.has_key?(properties, "dataBinding")))
  end

  defp template_properties?(_other), do: false

  defp ref_ends_with?(%{"$ref" => ref}, suffixes) when is_binary(ref),
    do: Enum.any?(suffixes, &String.ends_with?(ref, &1))

  defp ref_ends_with?(_schema, _suffixes), do: false

  # -- reference resolution ----------------------------------------------------------

  # Only `#/…` references are followed: first inside the component's own
  # `$defs`, then from the enclosing catalog's root.
  defp resolve_ref("#/" <> pointer, root, catalog) do
    [first | rest] = parts = String.split(pointer, "/")

    local =
      if first == "$defs", do: walk(root["$defs"], rest), else: nil

    cond do
      is_map(local) -> local
      is_map(catalog) -> walk(catalog, parts)
      true -> nil
    end
  end

  defp resolve_ref(_ref, _root, _catalog), do: nil

  defp walk(value, []), do: value
  defp walk(value, [part | rest]) when is_map(value), do: walk(Map.get(value, part), rest)
  defp walk(_value, _parts), do: nil
end

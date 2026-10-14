defmodule A2UIAgent.SchemaPruning do
  @moduledoc """
  Prunes the protocol schemas a prompt shows the model.

  Catalogs are pruned with `A2UIAgent.CatalogTransformer`; the
  agent-to-renderer and common types schemas belong to the protocol, so
  they are pruned here.
  """

  @moduledoc since: "0.1.0"

  @defs_prefix "#/$defs/"

  @doc """
  Keeps only the allowed messages of an agent-to-renderer schema.

  `allowed` names message actions (`"createSurface"`) or message
  definitions (`"CreateSurfaceMessage"`). The allowlist is read
  literally: an empty one admits no message and unknown names are
  ignored. Definitions only the removed messages use are removed too.

      iex> schema = %{
      ...>   "oneOf" => [%{"$ref" => "#/$defs/A"}, %{"$ref" => "#/$defs/B"}],
      ...>   "$defs" => %{
      ...>     "A" => %{"properties" => %{"createSurface" => %{"$ref" => "#/$defs/Shared"}}},
      ...>     "B" => %{"properties" => %{"deleteSurface" => %{}}},
      ...>     "Shared" => %{}
      ...>   }
      ...> }
      iex> pruned = A2UIAgent.SchemaPruning.prune_messages(schema, ["createSurface"])
      iex> {pruned["oneOf"], Map.keys(pruned["$defs"])}
      {[%{"$ref" => "#/$defs/A"}], ["A", "Shared"]}
  """
  @spec prune_messages(map(), [String.t()]) :: map()
  def prune_messages(schema, allowed) when is_map(schema) and is_list(allowed) do
    allowed_defs = allowed_definitions(schema["$defs"], MapSet.new(allowed))

    schema
    |> update_present("oneOf", &is_list/1, fn one_of ->
      for %{"$ref" => @defs_prefix <> name} = item <- one_of,
          MapSet.member?(allowed_defs, name),
          do: item
    end)
    |> update_present("$defs", &is_map/1, &reachable(&1, MapSet.to_list(allowed_defs)))
  end

  # The allowed names, plus each definition with a property one of them
  # names.
  defp allowed_definitions(defs, allowed) when is_map(defs) do
    for {name, %{"properties" => properties}} when is_map(properties) <- defs,
        Enum.any?(Map.keys(properties), &MapSet.member?(allowed, &1)),
        into: allowed,
        do: name
  end

  defp allowed_definitions(_defs, allowed), do: allowed

  @doc """
  Keeps only the common type definitions in use: those the
  `referencing` schemas refer to (as `common_types.json#/$defs/<name>` or
  `#/$defs/<name>`) and those a definition in use refers to.
  """
  @spec prune_common_types(map(), [map()]) :: map()
  def prune_common_types(common_types, referencing)
      when map_size(common_types) == 0 and is_list(referencing),
      do: %{}

  def prune_common_types(%{"$defs" => defs} = common_types, referencing) when is_map(defs) do
    roots =
      for schema <- referencing,
          ref <- refs(schema),
          String.contains?(ref, "common_types.json#/$defs/") or
            String.starts_with?(ref, @defs_prefix),
          uniq: true,
          do: ref |> String.split(@defs_prefix) |> List.last()

    Map.put(common_types, "$defs", reachable(defs, roots))
  end

  def prune_common_types(common_types, _referencing), do: common_types

  defp reachable(defs, roots), do: Map.take(defs, walk(roots, defs, %{}))

  defp walk([], _defs, seen), do: Map.keys(seen)

  defp walk([name | rest], defs, seen) do
    if Map.has_key?(defs, name) and not Map.has_key?(seen, name) do
      targets = for @defs_prefix <> target <- refs(defs[name]), do: target
      walk(targets ++ rest, defs, Map.put(seen, name, true))
    else
      walk(rest, defs, seen)
    end
  end

  # Every `$ref` string in a JSON value.
  defp refs(%{} = node) do
    Enum.flat_map(node, fn
      {"$ref", ref} when is_binary(ref) -> [ref]
      {_key, value} -> refs(value)
    end)
  end

  defp refs(list) when is_list(list), do: Enum.flat_map(list, &refs/1)
  defp refs(_other), do: []

  defp update_present(map, key, guard, fun) do
    case map do
      %{^key => value} -> if guard.(value), do: Map.put(map, key, fun.(value)), else: map
      _absent -> map
    end
  end
end

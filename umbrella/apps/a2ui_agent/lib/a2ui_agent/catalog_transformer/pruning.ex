defmodule A2UIAgent.CatalogTransformer.Pruning do
  @moduledoc """
  The pruning transformer behind `A2UIAgent.CatalogTransformer.component_pruning/1`
  and `A2UIAgent.CatalogTransformer.function_pruning/1`.
  """

  @behaviour A2UIAgent.CatalogTransformer

  alias A2UICore.Catalog

  @moduledoc since: "0.1.0"

  @impl true
  @spec transform(Catalog.t(), {:components | :functions, [String.t()]}) :: Catalog.t()
  def transform(%Catalog{} = catalog, {:components, names}),
    do: prune(catalog, Map.take(catalog.components, names), catalog.functions)

  def transform(%Catalog{} = catalog, {:functions, names}),
    do: prune(catalog, catalog.components, Map.take(catalog.functions, names))

  defp prune(catalog, components, functions) do
    roots =
      Enum.map(components, fn {_name, component} -> component.schema end) ++
        Enum.map(functions, fn {_name, function} -> function.schema end) ++ [catalog.theme]

    defs =
      catalog.defs
      |> Map.drop(["anyComponent", "anyFunction"])
      |> reachable(roots)

    Catalog.new!(catalog.catalog_id, catalog.protocol_version,
      components: Map.values(components),
      functions: Map.values(functions),
      theme: catalog.theme,
      instructions: catalog.instructions,
      defs: defs
    )
  end

  # The entries of `defs` that `roots` reach through `#/$defs/…`
  # references, directly or through other entries.
  defp reachable(defs, roots) do
    roots
    |> Enum.flat_map(&refs/1)
    |> walk(defs, %{})
    |> then(&Map.take(defs, Map.keys(&1)))
  end

  defp walk([], _defs, seen), do: seen

  defp walk([name | rest], defs, seen) do
    if Map.has_key?(defs, name) and not Map.has_key?(seen, name),
      do: walk(refs(defs[name]) ++ rest, defs, Map.put(seen, name, true)),
      else: walk(rest, defs, seen)
  end

  defp refs(%{} = node) do
    own =
      case node do
        %{"$ref" => "#/$defs/" <> target} -> [target |> String.split("/") |> hd()]
        _other -> []
      end

    own ++ Enum.flat_map(node, fn {_key, value} -> refs(value) end)
  end

  defp refs(list) when is_list(list), do: Enum.flat_map(list, &refs/1)
  defp refs(_other), do: []
end

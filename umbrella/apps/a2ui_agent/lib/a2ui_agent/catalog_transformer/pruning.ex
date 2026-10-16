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
    do:
      Catalog.copy_with(catalog,
        components: kept(catalog.components, catalog.component_order, names)
      )

  def transform(%Catalog{} = catalog, {:functions, names}),
    do:
      Catalog.copy_with(catalog,
        functions: kept(catalog.functions, catalog.function_order, names)
      )

  # The named entries, in the catalog's order. `Catalog.copy_with/2` lists
  # the unions from them and drops the `$defs` only dropped entries used.
  defp kept(entries, order, names) do
    allowed = MapSet.new(names)
    for name <- order, MapSet.member?(allowed, name), do: Map.fetch!(entries, name)
  end
end

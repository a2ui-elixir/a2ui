defmodule A2UIAgent.CatalogTransformer do
  @moduledoc """
  Rules applied to a catalog before it reaches a prompt or a validator.

  A transformer is either a module implementing this behaviour paired
  with its argument, `{module, argument}`, or a one-argument function.
  Either way it returns a new catalog. Transformers are registered on an
  `A2UIAgent.CatalogConfig`, which applies them in order.

  Two are built in:

    * `component_pruning/1` keeps only the named components;
    * `function_pruning/1` keeps only the named functions.

  The allowlist is read literally: an empty list (or `nil`) keeps
  nothing, and a name the catalog does not declare is ignored. To keep
  everything, apply no transformer. The pruned catalog's schema is
  rebuilt from what it keeps, so its `anyComponent`, `anyFunction` and
  helper `$defs` refer only to those entries.

      iex> {:ok, catalog} =
      ...>   A2UICore.Catalog.from_json(%{
      ...>     "catalogId" => "demo",
      ...>     "protocolVersion" => "v1.0",
      ...>     "components" => %{
      ...>       "Label" => %{"type" => "object", "properties" => %{"text" => %{"type" => "string"}}},
      ...>       "Badge" => %{"type" => "object", "properties" => %{"count" => %{"type" => "number"}}}
      ...>     }
      ...>   })
      iex> pruned =
      ...>   A2UIAgent.CatalogTransformer.apply_all(catalog, [
      ...>     A2UIAgent.CatalogTransformer.component_pruning(["Label", "Unknown"])
      ...>   ])
      iex> Map.keys(pruned.components)
      ["Label"]
  """

  alias A2UICore.Catalog

  @moduledoc since: "0.1.0"

  @typedoc "A transformer: `{module, argument}` or a function."
  @type t :: {module(), term()} | (Catalog.t() -> Catalog.t())

  @doc """
  Returns a new catalog derived from `catalog`.
  """
  @callback transform(Catalog.t(), argument :: term()) :: Catalog.t()

  @doc """
  Applies `transformers` to `catalog` one after another.
  """
  @spec apply_all(Catalog.t(), [t()] | nil) :: Catalog.t()
  def apply_all(%Catalog{} = catalog, nil), do: catalog

  def apply_all(%Catalog{} = catalog, transformers) when is_list(transformers),
    do: Enum.reduce(transformers, catalog, &apply_one/2)

  defp apply_one({module, argument}, catalog) when is_atom(module),
    do: module.transform(catalog, argument)

  defp apply_one(transformer, catalog) when is_function(transformer, 1),
    do: transformer.(catalog)

  @doc """
  A transformer that keeps only the named components. Functions and
  other definitions are kept.

  Raises `ArgumentError` for a single string, which is almost always a
  mistake for a one-element list.
  """
  @spec component_pruning([String.t()] | nil) :: t()
  def component_pruning(names),
    do: {A2UIAgent.CatalogTransformer.Pruning, {:components, allowlist(names, "component")}}

  @doc """
  A transformer that keeps only the named functions. Components and
  other definitions are kept.

  Raises `ArgumentError` for a single string.
  """
  @spec function_pruning([String.t()] | nil) :: t()
  def function_pruning(names),
    do: {A2UIAgent.CatalogTransformer.Pruning, {:functions, allowlist(names, "function")}}

  defp allowlist(nil, _kind), do: []

  defp allowlist(names, kind) when is_binary(names),
    do: raise(ArgumentError, "allowed #{kind}s must be a list of names, not a string")

  defp allowlist(names, _kind) when is_list(names), do: Enum.uniq(names)
end

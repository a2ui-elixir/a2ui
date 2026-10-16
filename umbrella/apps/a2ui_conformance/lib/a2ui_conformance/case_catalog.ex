defmodule A2UIConformance.CaseCatalog do
  @moduledoc false

  # The catalog a catalog-document case works on (reference harness
  # `_load_case_catalog`, `_with_case_peers`, `builtin_catalog`,
  # `sdk_catalog`, `normalize_set_keywords`).
  #
  # Files are decoded with their key order, which orders the components
  # and functions a catalog lists in its unions.

  alias A2UIConformance.Registry
  alias A2UICore.Catalog
  alias A2UICore.Catalog.{Basic, Document}

  @doc false
  # The case's catalog document: `catalogPath` (or `catalogFile`) read
  # from the reference checkout, else the inline `catalogSchema`,
  # `catalog` or `schema`, else the case itself.
  @spec document(map()) :: map() | Jason.OrderedObject.t()
  def document(raw) do
    case raw["catalogPath"] || raw["catalogFile"] do
      nil -> raw["catalogSchema"] || raw["catalog"] || raw["schema"] || raw
      path -> read(path)
    end
  end

  @doc false
  @spec read(String.t()) :: Jason.OrderedObject.t()
  def read(path) do
    [Registry.reference_root(), path]
    |> Path.join()
    |> File.read!()
    |> Jason.decode!(objects: :ordered_objects)
  end

  @doc false
  # The document as plain maps.
  @spec plain(term()) :: term()
  def plain(document), do: Document.to_plain(document)

  @doc false
  # Links the catalogs a case lists in `peerCatalogPaths` to `catalog`,
  # each loaded for the catalog's protocol version.
  @spec with_peers(Catalog.t(), map()) :: Catalog.t()
  def with_peers(catalog, raw) do
    case raw["peerCatalogPaths"] do
      [_ | _] = paths ->
        peers =
          Enum.map(
            paths,
            &Catalog.from_json!(read(&1), protocol_version: catalog.protocol_version)
          )

        Catalog.with_peer_catalogs(catalog, peers)

      _none ->
        catalog
    end
  end

  @doc false
  # The library's own implementation of a named catalog (`builtinCatalog`)
  # for a protocol version, or `nil`.
  @spec builtin(String.t(), String.t()) :: Catalog.t() | nil
  def builtin("basic", version), do: Basic.declared(version)
  def builtin(_name, _version), do: nil

  @doc false
  # The library's own implementation of the catalog with this id, or `nil`.
  @spec sdk_catalog(term()) :: Catalog.t() | nil
  def sdk_catalog(catalog_id) do
    ["v0.9", "v1.0"]
    |> Enum.map(&Basic.declared/1)
    |> Enum.find(&(&1.catalog_id == catalog_id))
  end

  @doc false
  # Sorts `enum` values and `required` names, which form sets.
  @spec normalize_sets(term()) :: term()
  def normalize_sets(%{} = node) do
    node = Map.new(node, fn {key, value} -> {key, normalize_sets(value)} end)

    Enum.reduce(["enum", "required"], node, fn keyword, acc ->
      case acc do
        %{^keyword => values} when is_list(values) -> Map.put(acc, keyword, Enum.sort(values))
        _other -> acc
      end
    end)
  end

  def normalize_sets(list) when is_list(list), do: Enum.map(list, &normalize_sets/1)
  def normalize_sets(other), do: other
end

defmodule A2UIAgent.CatalogConfig do
  @moduledoc """
  A catalog an agent registers, together with the transformers applied to
  it.

      config =
        A2UIAgent.CatalogConfig.new(catalog,
          transformers: [A2UIAgent.CatalogTransformer.component_pruning(["Text", "Button"])]
        )

      config.transformed
      #=> the pruned catalog, which prompts and validation use

  The transformed catalog is computed once, when the config is built.
  """

  alias A2UIAgent.{CatalogProvider, CatalogTransformer}
  alias A2UICore.{Catalog, Error}

  @moduledoc since: "0.1.0"

  @enforce_keys [:catalog, :transformed]
  defstruct [:catalog, :transformed, transformers: []]

  @type t :: %__MODULE__{
          catalog: Catalog.t(),
          transformers: [CatalogTransformer.t()],
          transformed: Catalog.t()
        }

  @doc """
  Registers `catalog`. Option: `:transformers`, applied in order.
  """
  @spec new(Catalog.t(), keyword()) :: t()
  def new(%Catalog{} = catalog, options \\ []) do
    transformers = Keyword.get(options, :transformers) || []

    %__MODULE__{
      catalog: catalog,
      transformers: transformers,
      transformed: CatalogTransformer.apply_all(catalog, transformers)
    }
  end

  @doc """
  Loads a catalog file with `A2UIAgent.CatalogProvider.load_file/2` and
  registers it. Options: `:transformers`, `:catalog_id`,
  `:protocol_version`.
  """
  @spec from_path(String.t(), keyword()) :: {:ok, t()} | {:error, Error.t()}
  def from_path(path, options \\ []) do
    case CatalogProvider.load_file(path, Keyword.take(options, [:catalog_id, :protocol_version])) do
      {:ok, catalog} -> {:ok, new(catalog, Keyword.take(options, [:transformers]))}
      {:error, error} -> {:error, error}
    end
  end
end

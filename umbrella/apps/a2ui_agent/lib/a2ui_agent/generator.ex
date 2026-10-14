defmodule A2UIAgent.Generator do
  @moduledoc """
  The agent-level entry point: the catalogs an agent supports, its
  few-shot examples and its inference format, from which it creates one
  `A2UIAgent.RequestProcessor` per request.

      {:ok, config} = A2UIAgent.CatalogConfig.from_path("catalogs/basic.json")
      generator = A2UIAgent.Generator.new([config], examples: [turn])

      # per request, with the capabilities the renderer sent:
      {:ok, processor} = A2UIAgent.Generator.create_processor(generator, capabilities)

  Catalog negotiation follows `A2UIAgent.CatalogResolver`.
  """

  alias A2UIAgent.{CatalogConfig, CatalogResolver, Format, RequestProcessor}
  alias A2UICore.Error

  @moduledoc since: "0.1.0"

  defstruct catalogs: [],
            examples: nil,
            format: A2UIAgent.DirectJson,
            accepts_inline_catalogs: false

  @type t :: %__MODULE__{
          catalogs: [CatalogConfig.t()],
          examples: [[map()]] | nil,
          format: Format.spec(),
          accepts_inline_catalogs: boolean()
        }

  @doc """
  Creates a generator over the registered catalogs.

  Options: `:examples`; `:format` (an `t:A2UIAgent.Format.spec/0`,
  `A2UIAgent.DirectJson` by default); `:accepts_inline_catalogs`
  (default `false`).
  """
  @spec new([CatalogConfig.t()], keyword()) :: t()
  def new(catalogs, options \\ []) when is_list(catalogs) do
    %__MODULE__{
      catalogs: catalogs,
      examples: options[:examples],
      format: Keyword.get(options, :format, A2UIAgent.DirectJson),
      accepts_inline_catalogs: Keyword.get(options, :accepts_inline_catalogs, false)
    }
  end

  @doc """
  Creates the processor for a renderer's capabilities.

  A processor is negotiated for one renderer, so `nil` capabilities are a
  `:catalog` error here (although `A2UIAgent.CatalogResolver.resolve/3`
  accepts them). Option: `:format` overrides the generator's format for
  this processor.
  """
  @spec create_processor(t(), map() | nil, keyword()) ::
          {:ok, RequestProcessor.t()} | {:error, Error.t()}
  def create_processor(generator, capabilities, options \\ [])

  def create_processor(%__MODULE__{}, nil, _options) do
    {:error,
     Error.new(
       :catalog,
       "CATALOG_ERROR",
       "Renderer capabilities are required to create a request processor."
     )}
  end

  def create_processor(%__MODULE__{} = generator, capabilities, options) do
    with {:ok, active} <-
           CatalogResolver.resolve(generator.catalogs, capabilities,
             accepts_inline_catalogs: generator.accepts_inline_catalogs
           ) do
      RequestProcessor.new(active,
        examples: generator.examples,
        format: Keyword.get(options, :format) || generator.format
      )
    end
  end
end

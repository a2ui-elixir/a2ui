defmodule A2UIAgent.RequestProcessor do
  @moduledoc """
  Everything an agent needs to answer one request: the negotiated
  catalogs, the inference format bound to them, its prompt snippet and
  its parsers.

  A processor is normally created by `A2UIAgent.Generator.create_processor/3`
  from the renderer's capabilities.

      {:ok, processor} = A2UIAgent.RequestProcessor.new(catalogs, examples: [turn])
      {:ok, prompt} = A2UIAgent.RequestProcessor.prompt(processor)
      {:ok, parts} = A2UIAgent.RequestProcessor.parse_response(processor, model_output)
  """

  alias A2UIAgent.DirectJson.Parser
  alias A2UIAgent.{Format, PayloadValidator}
  alias A2UICore.{Catalog, Error}

  @moduledoc since: "0.1.0"

  @enforce_keys [:catalogs, :format]
  defstruct [:catalogs, :format, :examples]

  @type t :: %__MODULE__{
          catalogs: [Catalog.t()],
          format: struct(),
          examples: [[map()]] | nil
        }

  @doc """
  Creates a processor over the active `catalogs`.

  Options: `:examples` — few-shot example turns, each checked with
  `A2UIAgent.PayloadValidator` against the catalogs; `:format` — the
  `t:A2UIAgent.Format.spec/0` (`A2UIAgent.DirectJson` by default).
  """
  @spec new([Catalog.t()], keyword()) :: {:ok, t()} | {:error, Error.t()}
  def new(catalogs, options \\ [])

  def new([], _options),
    do: {:error, Error.new(:catalog, "CATALOG_ERROR", "At least one active catalog is required.")}

  def new(catalogs, options) do
    examples = options[:examples]

    with :ok <- validate_examples(catalogs, examples),
         {:ok, format} <-
           Format.create(Keyword.get(options, :format, A2UIAgent.DirectJson), catalogs, examples) do
      {:ok, %__MODULE__{catalogs: catalogs, format: format, examples: examples}}
    end
  end

  defp validate_examples(_catalogs, nil), do: :ok

  defp validate_examples(catalogs, examples) do
    Enum.reduce_while(examples, :ok, fn turn, :ok ->
      case PayloadValidator.validate(catalogs, turn) do
        :ok -> {:cont, :ok}
        {:error, error} -> {:halt, {:error, error}}
      end
    end)
  end

  @doc "The active catalogs, in the renderer's order of preference."
  @spec active_catalogs(t()) :: [Catalog.t()]
  def active_catalogs(%__MODULE__{catalogs: catalogs}), do: catalogs

  @doc "The format's system prompt snippet."
  @spec prompt(t()) :: {:ok, String.t()} | {:error, Error.t()}
  def prompt(%__MODULE__{format: %module{} = format}), do: module.prompt(format)

  @doc "A fresh parser bound to the active catalogs."
  @spec parser(t()) :: struct()
  def parser(%__MODULE__{format: %module{} = format}), do: module.parser(format)

  @doc """
  Parses and validates a complete model response with a fresh parser.
  Option: `:wrapped` (default `true`).
  """
  @spec parse_response(t(), String.t(), keyword()) ::
          {:ok, [Parser.part()]} | {:error, Error.t()}
  def parse_response(%__MODULE__{} = processor, content, options \\ []) do
    %parser_module{} = parser = parser(processor)
    parser_module.parse_response(parser, content, options)
  end
end

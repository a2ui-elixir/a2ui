defmodule A2UIAgent.DirectJson do
  @moduledoc """
  The direct JSON inference format: the model writes A2UI messages as
  JSON between `<a2ui-json>` and `</a2ui-json>` tags, guided by the
  protocol and catalog JSON schemas in its prompt.

      {:ok, format} = A2UIAgent.DirectJson.new(catalogs, examples: [example_turn])
      {:ok, prompt} = A2UIAgent.DirectJson.prompt(format)
      parser = A2UIAgent.DirectJson.parser(format)

  Options:

    * `:examples` — few-shot example turns (lists of messages) rendered
      into the prompt;
    * `:allowed_messages` — the message actions the prompt describes
      (`nil`, the default, describes all of them);
    * `:progressive_keys` — string properties the streaming parser may
      emit before their closing quote (`progressive_keys/0` lists the
      usual ones).

  See `A2UIAgent.DirectJson.Prompt` for the prompt and
  `A2UIAgent.DirectJson.Parser` for reading responses.
  """

  @behaviour A2UIAgent.Format

  alias A2UIAgent.Catalogs
  alias A2UIAgent.DirectJson.{Parser, Prompt}
  alias A2UICore.{Catalog, Error}

  @moduledoc since: "0.1.0"

  @progressive_keys ~w(literalString valueString label hint caption altText text)

  defstruct catalogs: [], examples: nil, allowed_messages: nil, progressive_keys: []

  @type t :: %__MODULE__{
          catalogs: [Catalog.t()],
          examples: [[map()]] | nil,
          allowed_messages: [String.t()] | nil,
          progressive_keys: [String.t()]
        }

  @doc """
  Creates the format. The catalogs must be non-empty, have distinct ids
  and share a protocol version.
  """
  @impl A2UIAgent.Format
  @spec new([Catalog.t()], keyword()) :: {:ok, t()} | {:error, Error.t()}
  def new(catalogs, options \\ []) do
    with {:ok, catalogs} <- Catalogs.check(catalogs) do
      {:ok,
       %__MODULE__{
         catalogs: catalogs,
         examples: options[:examples],
         allowed_messages: options[:allowed_messages],
         progressive_keys: Keyword.get(options, :progressive_keys) || []
       }}
    end
  end

  @doc "The system prompt snippet; see `A2UIAgent.DirectJson.Prompt`."
  @impl A2UIAgent.Format
  @spec prompt(t()) :: {:ok, String.t()} | {:error, Error.t()}
  def prompt(%__MODULE__{} = format),
    do:
      Prompt.generate(format.catalogs,
        examples: format.examples,
        allowed_messages: format.allowed_messages
      )

  @doc "A fresh parser for the format's catalogs."
  @impl A2UIAgent.Format
  @spec parser(t()) :: Parser.t()
  def parser(%__MODULE__{} = format) do
    {:ok, parser} = Parser.new(format.catalogs, progressive_keys: format.progressive_keys)
    parser
  end

  @doc """
  The string properties commonly healed while streaming.

      iex> "text" in A2UIAgent.DirectJson.progressive_keys()
      true
  """
  @spec progressive_keys() :: [String.t()]
  def progressive_keys, do: @progressive_keys
end

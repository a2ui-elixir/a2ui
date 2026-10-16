defmodule A2UIAgent.Express do
  @moduledoc """
  The Express inference format: the model writes a compact,
  function-call notation between `<a2ui>` and `</a2ui>` tags, which the
  agent compiles into A2UI messages.

      <a2ui>
      surface("booking")
      $/form/name = ""
      root = Card(form)
      form = Column([TextField("Name", $/form/name, ?required), submit])
      submit = Button(Text("Book"), action=Event("book", {name: $/form/name}))
      </a2ui>

  Components take their properties positionally in the order their
  catalog schema declares them (or by keyword), variables name
  components, `$` paths bind data, `?name` writes a check rule and
  `Event(...)` an action. The grammar is
  `specification/inference_formats/express/Express.g4`;
  `A2UIAgent.Express.Compiler` describes how each statement compiles.

  Because arguments are positional, a catalog must be read with the key
  order of its document: `A2UICore.Catalog.Basic`,
  `A2UIAgent.CatalogConfig.from_path/2` and `A2UIAgent.CatalogProvider`
  keep it. A catalog built from a map (a document decoded without
  `objects: :ordered_objects`) has its properties ordered by name.

      {:ok, format} = A2UIAgent.Express.new(catalogs, examples: [example_turn])
      {:ok, prompt} = A2UIAgent.Express.prompt(format)
      parser = A2UIAgent.Express.parser(format)

  Options:

    * `:examples` — few-shot example turns (lists of messages), rendered
      into the prompt as Express;
    * `:allowed_messages` — the message actions the prompt teaches
      (`nil`, the default, teaches all of them);
    * `:surface_id` — the surface of statements before any `surface`
      line (default `"main"`);
    * `:version` — the protocol version to write (default: the
      catalogs').

  See `A2UIAgent.Express.Prompt` for the prompt and
  `A2UIAgent.Express.Parser` for reading responses. The format also
  provides the pieces `A2UIAgent.SkillGenerator` builds skills from.
  """

  @behaviour A2UIAgent.Format

  alias A2UIAgent.Express.{Catalogs, Parser, Prompt}
  alias A2UICore.{Catalog, Error}

  @moduledoc since: "0.1.0"

  defstruct [:catalogs, examples: nil, allowed_messages: nil, surface_id: "main"]

  @type t :: %__MODULE__{
          catalogs: Catalogs.t(),
          examples: [[map()]] | nil,
          allowed_messages: [String.t()] | nil,
          surface_id: String.t()
        }

  @doc """
  Creates the format. The catalogs must be non-empty, have distinct ids
  and share a protocol version; several catalogs need v1.0.
  """
  @impl A2UIAgent.Format
  @spec new([Catalog.t()], keyword()) :: {:ok, t()} | {:error, Error.t()}
  def new(catalogs, options \\ []) do
    with {:ok, resolved} <- Catalogs.new(catalogs, options[:version]) do
      {:ok,
       %__MODULE__{
         catalogs: resolved,
         examples: options[:examples],
         allowed_messages: options[:allowed_messages],
         surface_id: options[:surface_id] || "main"
       }}
    end
  end

  @doc "The system prompt snippet; see `A2UIAgent.Express.Prompt`."
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
  def parser(%__MODULE__{} = format),
    do: %Parser{catalogs: format.catalogs, surface_id: format.surface_id}

  @doc "The format's active catalogs, in order."
  @impl A2UIAgent.Format
  @spec catalogs(t()) :: [Catalog.t()]
  def catalogs(%__MODULE__{catalogs: catalogs}), do: catalogs.catalogs

  @doc "The grammar rules of the prompt; see `A2UIAgent.Express.Prompt.base_rules/2`."
  @impl A2UIAgent.Format
  @spec base_rules(t()) :: String.t()
  def base_rules(%__MODULE__{} = format),
    do: Prompt.base_rules(format.catalogs, format.allowed_messages)

  @doc """
  The signatures and instructions of one catalog (by id), or of all of
  them; see `A2UIAgent.Express.Prompt.catalog_instructions/2`.
  """
  @impl A2UIAgent.Format
  @spec catalog_instructions(t(), String.t() | nil) :: String.t()
  def catalog_instructions(%__MODULE__{} = format, catalog_id \\ nil),
    do: Prompt.catalog_instructions(format.catalogs, catalog_id)

  @doc """
  The example turns as Express blocks. Examples are not kept per
  catalog, so every catalog has the same ones.
  """
  @impl A2UIAgent.Format
  @spec examples(t(), String.t() | nil) :: {:ok, String.t()} | {:error, Error.t()}
  def examples(%__MODULE__{} = format, _catalog_id \\ nil),
    do: Prompt.examples(format.catalogs, format.examples)
end

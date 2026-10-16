defmodule A2UIAgent.Express.Parser do
  @moduledoc """
  Reads model output written in Express: conversational text with
  Express blocks between `<a2ui>` and `</a2ui>` tags.

      {:ok, parser} = A2UIAgent.Express.Parser.new(catalogs, surface_id: "main")

      {:ok, parts} =
        A2UIAgent.Express.Parser.parse_response(parser, \"\"\"
        Here it is.
        <a2ui>
        root = Text("Hello")
        </a2ui>
        \"\"\")

      parts
      #=> [{:text, "Here it is."}, {:a2ui, [%{"version" => "v1.0", "createSurface" => ...}]}]

  Blocks are found with `A2UIAgent.BlockLexer` (a closing tag inside a
  string or comment does not close a block) and compiled with
  `A2UIAgent.Express.Compiler`. Express is not read incrementally: a
  response is parsed once it is complete.

  Parts are `{:text, text}` and `{:a2ui, messages}`. `unwrap/1` returns
  raw parts, `{:text, text}` and `{:a2ui_raw, block, final?}`.
  """

  alias A2UIAgent.BlockLexer
  alias A2UIAgent.Express.{Catalogs, Compiler, Decompiler}
  alias A2UICore.{Catalog, Error}

  @moduledoc since: "0.1.0"

  defstruct [:catalogs, surface_id: "main"]

  @type t :: %__MODULE__{catalogs: Catalogs.t(), surface_id: String.t()}

  @typedoc "A part of a parsed response."
  @type part :: {:text, String.t()} | {:a2ui, [map()]}

  @doc """
  Creates a parser for `catalogs`. Options: `:surface_id`, the surface
  of statements before any `surface` line (default `"main"`), and
  `:version`, the protocol version to write (default: the catalogs').
  """
  @spec new([Catalog.t()], keyword()) :: {:ok, t()} | {:error, Error.t()}
  def new(catalogs, options \\ []) do
    with {:ok, resolved} <- Catalogs.new(catalogs, options[:version]) do
      {:ok,
       %__MODULE__{catalogs: resolved, surface_id: Keyword.get(options, :surface_id, "main")}}
    end
  end

  @doc """
  Whether `content` holds an `<a2ui>` block; with `complete: true`, a
  block whose closing tag has arrived.
  """
  @spec has_format_content?(String.t(), keyword()) :: boolean()
  def has_format_content?(content, options \\ []) do
    complete? = Keyword.get(options, :complete, false)

    content
    |> unwrap()
    |> Enum.any?(fn
      {:a2ui_raw, _raw, final?} -> final? or not complete?
      {:text, _text} -> false
    end)
  end

  @doc "Splits model output into text and raw Express blocks."
  @spec unwrap(String.t()) :: [BlockLexer.raw_part()]
  def unwrap(content), do: BlockLexer.tokenize(content)

  @doc """
  Writes parts out as model output, joined by newlines: text as it is,
  each block between tags.
  """
  @spec wrap([BlockLexer.raw_part() | {:a2ui_raw, String.t()}]) :: String.t()
  def wrap(parts) do
    Enum.map_join(parts, "\n", fn
      {:text, text} -> text
      {:a2ui_raw, raw} -> "<a2ui>\n#{raw}\n</a2ui>"
      {:a2ui_raw, raw, _final?} -> "<a2ui>\n#{raw}\n</a2ui>"
    end)
  end

  @doc """
  Compiles one block (see `A2UIAgent.Express.Compiler.compile/3`). With
  `final: false`, the statements before the block's first syntax error
  compile.
  """
  @spec compile(t(), String.t(), keyword()) :: {:ok, [map()]} | {:error, Error.t()}
  def compile(%__MODULE__{} = parser, block, options \\ []) do
    Compiler.compile(parser.catalogs, block,
      surface_id: parser.surface_id,
      final: Keyword.get(options, :final, true)
    )
  end

  @doc """
  Writes messages back as Express; see `A2UIAgent.Express.Decompiler.decompile/3`
  for the options.
  """
  @spec decompile(t(), [map()] | map(), keyword()) :: {:ok, String.t()} | {:error, Error.t()}
  def decompile(%__MODULE__{catalogs: catalogs}, messages, options \\ []),
    do: Decompiler.decompile(catalogs, messages, options)

  @doc "Encloses decompiled blocks in one pair of tags."
  @spec wrap_decompiled_blocks([String.t()]) :: String.t()
  defdelegate wrap_decompiled_blocks(blocks), to: Decompiler

  @doc """
  Parses a complete model response into parts.

  With `wrapped: false` the whole response is one block. Otherwise each
  block is compiled in turn (a block whose closing tag never came as not
  final) and the first failure is returned.
  """
  @spec parse_response(t(), String.t(), keyword()) :: {:ok, [part()]} | {:error, Error.t()}
  def parse_response(%__MODULE__{} = parser, content, options \\ []) do
    if Keyword.get(options, :wrapped, true) do
      content |> unwrap() |> compile_parts(parser, [])
    else
      with {:ok, messages} <- compile(parser, content), do: {:ok, [{:a2ui, messages}]}
    end
  end

  defp compile_parts([], _parser, parts), do: {:ok, Enum.reverse(parts)}

  defp compile_parts([{:text, text} | rest], parser, parts),
    do: compile_parts(rest, parser, [{:text, text} | parts])

  defp compile_parts([{:a2ui_raw, block, final?} | rest], parser, parts) do
    with {:ok, messages} <- compile(parser, block, final: final?),
         do: compile_parts(rest, parser, [{:a2ui, messages} | parts])
  end

  @doc "Express is read once a response is complete, never chunk by chunk."
  @spec supports_streaming?() :: false
  def supports_streaming?, do: false
end

defmodule A2UIAgent.DirectJson.Parser do
  @moduledoc """
  Reads model output written in the direct JSON format: conversational
  text with A2UI message lists between `<a2ui-json>` and `</a2ui-json>`
  tags.

      {:ok, parser} = A2UIAgent.DirectJson.Parser.new(catalogs)

      {:ok, parts} =
        A2UIAgent.DirectJson.Parser.parse_response(parser, \"\"\"
        Here is your surface.
        <a2ui-json>[{"version": "v1.0", "deleteSurface": {"surfaceId": "s1"}}]</a2ui-json>
        \"\"\")

      parts
      #=> [{:text, "Here is your surface."},
      #    {:a2ui, [%{"version" => "v1.0", "deleteSurface" => %{"surfaceId" => "s1"}}]}]

  A block is read leniently (`A2UIAgent.DirectJson.JsonReader`: trailing
  commas, raw line breaks in strings, curly quotes), a Markdown code
  fence around it is dropped, and a single message is read as a list of
  one. The messages are then checked with
  `A2UIAgent.PayloadValidator`.

  Parts are `{:text, text}` and `{:a2ui, messages}`. `unwrap/1` returns
  raw parts, `{:text, text}` and `{:a2ui_raw, block, final?}`, where
  `final?` is false for a block whose closing tag has not arrived.
  """

  alias A2UIAgent.{Catalogs, PayloadValidator}
  alias A2UIAgent.DirectJson.JsonReader
  alias A2UICore.{Catalog, Error}

  @moduledoc since: "0.1.0"

  @open_tag "<a2ui-json>"
  @close_tag "</a2ui-json>"

  defstruct catalogs: [],
            progressive_keys: MapSet.new(),
            wrapped: nil,
            in_block: false,
            held: "",
            block: "",
            run_started: false,
            held_space: "",
            emitted: []

  @type t :: %__MODULE__{
          catalogs: [Catalog.t()],
          progressive_keys: MapSet.t(String.t()),
          wrapped: boolean() | nil,
          in_block: boolean(),
          held: String.t(),
          block: String.t(),
          run_started: boolean(),
          held_space: String.t(),
          emitted: [String.t()]
        }

  @typedoc "A part of a parsed response."
  @type part :: {:text, String.t()} | {:a2ui, [map()]}

  @typedoc "A part of an unwrapped response: text or an uncompiled block."
  @type raw_part :: {:text, String.t()} | {:a2ui_raw, String.t(), boolean()}

  @doc """
  Creates a parser for `catalogs` (default catalog first). Option:
  `:progressive_keys` — string properties the streaming reader may emit
  before their closing quote.

  The catalogs must be non-empty, have distinct ids and share a protocol
  version.
  """
  @spec new([Catalog.t()], keyword()) :: {:ok, t()} | {:error, Error.t()}
  def new(catalogs, options \\ []) do
    with {:ok, catalogs} <- Catalogs.check(catalogs) do
      {:ok,
       %__MODULE__{
         catalogs: catalogs,
         progressive_keys: MapSet.new(Keyword.get(options, :progressive_keys) || [])
       }}
    end
  end

  @doc """
  Whether `content` holds an `<a2ui-json>` block; with `complete: true`,
  a block whose closing tag has arrived.
  """
  @spec has_format_content?(String.t(), keyword()) :: boolean()
  def has_format_content?(content, options \\ []) do
    case Regex.run(open_tag_re(), content, return: :index) do
      nil ->
        false

      [{start, length}] ->
        not Keyword.get(options, :complete, false) or
          match?({close, _} when is_integer(close), scan_block(content, start + length))
    end
  end

  @doc """
  Writes parts out as model output: text as it is, each block between
  tags, joined by newlines.
  """
  @spec wrap([raw_part() | {:a2ui_raw, String.t()}]) :: String.t()
  def wrap(parts) do
    Enum.map_join(parts, "\n", fn
      {:text, text} -> text
      {:a2ui_raw, raw} -> "#{@open_tag}\n#{raw}\n#{@close_tag}"
      {:a2ui_raw, raw, _final?} -> "#{@open_tag}\n#{raw}\n#{@close_tag}"
    end)
  end

  @doc """
  Splits model output into text and raw blocks, without compiling them.
  """
  @spec unwrap(String.t()) :: [raw_part()]
  def unwrap(content), do: unwrap(content, 0, [])

  defp unwrap(content, from, parts) do
    case Regex.run(open_tag_re(), content, return: :index, offset: from) do
      nil ->
        Enum.reverse(add_text(parts, slice(content, from)))

      [{start, length}] ->
        parts = add_text(parts, binary_part(content, from, start - from))
        block_start = start + length

        case scan_block(content, block_start) do
          {nil, _readable} ->
            Enum.reverse([{:a2ui_raw, clean(slice(content, block_start)), false} | parts])

          {close, _readable} ->
            block = clean(binary_part(content, block_start, close - block_start))

            [{^close, close_length}] =
              Regex.run(close_tag_re(), content, return: :index, offset: close)

            unwrap(content, close + close_length, [{:a2ui_raw, block, true} | parts])
        end
    end
  end

  defp add_text(parts, text) do
    case clean(text) do
      "" -> parts
      cleaned -> [{:text, cleaned} | parts]
    end
  end

  @doc """
  Compiles one block into validated messages.

  An empty block or one that does not read as JSON is a `:parse` error;
  messages a renderer holding the catalogs would reject are a
  `:validation` error.
  """
  @spec compile(t(), String.t()) :: {:ok, [map()]} | {:error, Error.t()}
  def compile(%__MODULE__{catalogs: catalogs}, block) do
    with {:ok, cleaned} <- non_empty(clean(block)),
         {:ok, decoded} <- read(cleaned),
         messages = if(is_list(decoded), do: decoded, else: [decoded]),
         :ok <- PayloadValidator.validate(catalogs, messages) do
      {:ok, messages}
    end
  end

  defp non_empty(""), do: {:error, parse_error("The direct JSON block is empty.")}
  defp non_empty(cleaned), do: {:ok, cleaned}

  defp read(cleaned) do
    case JsonReader.read(cleaned) do
      {:ok, decoded} -> {:ok, decoded}
      {:error, reason} -> {:error, parse_error("The direct JSON block is not JSON: #{reason}")}
    end
  end

  @doc """
  Writes messages back out as the pretty-printed JSON a model would have
  emitted.
  """
  @spec decompile([map()] | map()) :: String.t()
  def decompile(messages) when is_list(messages), do: Jason.encode!(messages, pretty: true)
  def decompile(message) when is_map(message), do: decompile([message])

  @doc """
  Encloses decompiled blocks in one pair of tags.
  """
  @spec wrap_decompiled_blocks([String.t()]) :: String.t()
  def wrap_decompiled_blocks(blocks),
    do: "#{@open_tag}\n#{Enum.join(blocks, "\n")}\n#{@close_tag}"

  @doc """
  Parses a complete model response into parts.

  With `wrapped: false` the whole response is one block. Otherwise each
  block is compiled in turn and the first failure is returned.
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

  defp compile_parts([{:a2ui_raw, block, _final?} | rest], parser, parts) do
    with {:ok, messages} <- compile(parser, block),
         do: compile_parts(rest, parser, [{:a2ui, messages} | parts])
  end

  # -- streaming ----------------------------------------------------------------------

  @doc """
  Reads the next chunk of a streamed response and returns the parts it
  completes or changes.

  Text is emitted as it arrives, trimmed at the edges of each run of
  text; a possible start of an `<a2ui-json>` tag is held back until the
  next chunk settles it. Inside a block, each message is emitted as soon
  as it reads (`A2UIAgent.DirectJson.JsonReader.read_partial_items/3`)
  and validates, and again whenever it grows; a message that has not
  changed is not emitted twice. A `createSurface` waits until its object
  closes, and so do the messages after it. When the block closes it is
  compiled in full, so a block that does not validate is an error then.

  With `wrapped: false` the whole response is one block without tags. A
  response is either wrapped or not: every chunk must say the same.
  """
  @spec parse_chunk(t(), String.t(), keyword()) :: {:ok, t(), [part()]} | {:error, Error.t()}
  def parse_chunk(%__MODULE__{} = parser, chunk, options \\ []) do
    wrapped = Keyword.get(options, :wrapped, true)

    parser =
      case parser.wrapped do
        nil ->
          %{parser | wrapped: wrapped, in_block: not wrapped}

        ^wrapped ->
          parser

        first ->
          raise ArgumentError,
                "a response is either wrapped or not; the first chunk said #{first}"
      end

    if wrapped do
      stream(%{parser | held: ""}, parser.held <> chunk, [])
    else
      parser = %{parser | block: parser.block <> chunk}
      {parser, parts} = emit_ready(parser, parser.block, [])
      {:ok, parser, Enum.reverse(parts)}
    end
  end

  defp stream(parser, "", parts), do: {:ok, parser, Enum.reverse(parts)}

  defp stream(%__MODULE__{in_block: true} = parser, input, parts) do
    block = parser.block <> input

    case scan_block(block, 0) do
      {nil, readable} ->
        {parser, parts} =
          emit_ready(%{parser | block: block}, binary_part(block, 0, readable), parts)

        {:ok, parser, Enum.reverse(parts)}

      {close, _readable} ->
        [{^close, length}] = Regex.run(close_tag_re(), block, return: :index, offset: close)

        case compile(parser, binary_part(block, 0, close)) do
          {:ok, messages} ->
            {parser, parts} = emit_changed(parser, messages, parts)
            parser = %{parser | in_block: false, block: "", emitted: []}
            stream(parser, slice(block, close + length), parts)

          {:error, error} ->
            {:error, error}
        end
    end
  end

  defp stream(parser, input, parts) do
    case Regex.run(open_tag_re(), input, return: :index) do
      [{start, length}] ->
        {parser, parts} = emit_text(parser, binary_part(input, 0, start), parts)
        parser = %{parser | run_started: false, held_space: "", in_block: true}
        stream(parser, slice(input, start + length), parts)

      nil ->
        hold = possible_tag_start(input)
        {parser, parts} = emit_text(parser, binary_part(input, 0, hold), parts)
        {:ok, %{parser | held: slice(input, hold)}, Enum.reverse(parts)}
    end
  end

  # Text is trimmed at the start and end of each run of text between
  # blocks; whitespace inside a run is kept, even across chunks.
  defp emit_text(parser, text, parts) do
    leading = if parser.run_started, do: text, else: String.trim_leading(text)

    case String.trim_trailing(leading) do
      "" ->
        if parser.run_started,
          do: {%{parser | held_space: parser.held_space <> text}, parts},
          else: {parser, parts}

      body ->
        start = byte_size(text) - byte_size(leading)
        trailing = slice(text, start + byte_size(body))

        {%{parser | held_space: trailing, run_started: true},
         [{:text, parser.held_space <> body} | parts]}
    end
  end

  defp emit_ready(parser, block, parts) do
    whole_item_keys = if v1?(parser), do: ["components"], else: []

    items =
      JsonReader.read_partial_items(clean_start(block), parser.progressive_keys, whole_item_keys)

    ready = ready_messages(parser.catalogs, items, parser.emitted, %{}, [])
    emit_changed(parser, ready, parts)
  end

  # The messages that read and validate, in order, up to the first that
  # does not. A create message waits until its object closes, since a
  # renderer accepts it only once. A message emitted before, after the
  # same messages, validated then and is not checked again.
  defp ready_messages(_catalogs, [], _emitted, _surfaces, ready), do: Enum.reverse(ready)

  defp ready_messages(catalogs, [{envelope, closed?} | rest], emitted, surfaces, ready) do
    {seen?, emitted} =
      case emitted do
        [^envelope | later] -> {true, later}
        _changed -> {false, []}
      end

    if is_map(envelope) and
         (seen? or (ready_to_check?(envelope, closed?) and valid?(catalogs, envelope, surfaces))),
       do:
         ready_messages(catalogs, rest, emitted, track_surfaces(surfaces, envelope), [
           envelope | ready
         ]),
       else: Enum.reverse(ready)
  end

  defp ready_to_check?(envelope, closed?),
    do: closed? or not Map.has_key?(envelope, "createSurface")

  defp valid?(catalogs, envelope, surfaces),
    do: PayloadValidator.validate(catalogs, [envelope], surface_catalog_ids: surfaces) == :ok

  defp track_surfaces(surfaces, envelope) do
    surfaces =
      case envelope["createSurface"] do
        %{"surfaceId" => id, "catalogId" => catalog_id}
        when is_binary(id) and is_binary(catalog_id) ->
          Map.put(surfaces, id, catalog_id)

        _other ->
          surfaces
      end

    case envelope["deleteSurface"] do
      %{"surfaceId" => id} when is_binary(id) -> Map.delete(surfaces, id)
      _other -> surfaces
    end
  end

  # Emits the messages that are new or differ from what the same position
  # emitted last time.
  defp emit_changed(parser, messages, parts) do
    {changed, emitted} =
      messages
      |> Enum.with_index()
      |> Enum.reduce({[], parser.emitted}, fn {message, index}, {changed, emitted} ->
        cond do
          index >= length(emitted) -> {[message | changed], emitted ++ [message]}
          Enum.at(emitted, index) === message -> {changed, emitted}
          true -> {[message | changed], List.replace_at(emitted, index, message)}
        end
      end)

    parser = %{parser | emitted: emitted}

    case changed do
      [] -> {parser, parts}
      changed -> {parser, [{:a2ui, Enum.reverse(changed)} | parts]}
    end
  end

  # The offset of a `<` that may start an open tag the next chunk
  # completes, or the length of `text`.
  defp possible_tag_start(text), do: possible_tag_start(text, 0)

  defp possible_tag_start(text, from) do
    case :binary.match(text, "<", scope: {from, byte_size(text) - from}) do
      :nomatch ->
        byte_size(text)

      {at, _length} ->
        rest = slice(text, at)

        if String.starts_with?("<a2ui-json", String.downcase(rest)) or
             Regex.match?(~r/\A<a2ui-json\s[^>]*\z/iu, rest),
           do: at,
           else: possible_tag_start(text, at + 1)
    end
  end

  # A streamed block may open with a code fence whose first line has not
  # ended yet, and end with part of the closing fence.
  defp clean_start(block) do
    text = String.trim_leading(block)

    text =
      if String.starts_with?(text, "`") do
        case :binary.match(text, "\n") do
          {at, _length} -> slice(text, at + 1)
          :nomatch -> ""
        end
      else
        text
      end

    String.replace(text, ~r/\s*`{1,3}[a-zA-Z-]*\s*\z/u, "", global: false)
  end

  defp v1?(%__MODULE__{catalogs: [first | _]}), do: Catalog.v1?(first)

  # -- scanning -----------------------------------------------------------------------

  @doc false
  # Finds the closing tag of a block that starts at byte `from`, outside
  # JSON strings. Returns `{close_offset | nil, readable_length}`: when a
  # possible start of the closing tag ends the text, the readable part
  # stops before it.
  @spec scan_block(String.t(), non_neg_integer()) :: {non_neg_integer() | nil, non_neg_integer()}
  def scan_block(content, from), do: scan(content, from, from, byte_size(content), false)

  defp scan(_content, from, i, size, _in_string) when i >= size, do: {nil, size - from}

  defp scan(content, from, i, size, true) do
    case :binary.at(content, i) do
      ?\\ -> scan(content, from, i + 2, size, true)
      ?" -> scan(content, from, i + 1, size, false)
      _other -> scan(content, from, i + 1, size, true)
    end
  end

  defp scan(content, from, i, size, false) do
    case :binary.at(content, i) do
      ?" -> scan(content, from, i + 1, size, true)
      ?< -> at_angle(content, from, i, size)
      _other -> scan(content, from, i + 1, size, false)
    end
  end

  defp at_angle(content, from, i, size) do
    rest = binary_part(content, i, size - i)

    cond do
      Regex.match?(close_tag_at_start_re(), rest) -> {i, i - from}
      possible_close_tag?(String.downcase(rest)) -> {nil, i - from}
      true -> scan(content, from, i + 1, size, false)
    end
  end

  defp possible_close_tag?(rest),
    do: String.starts_with?(@close_tag, rest) or Regex.match?(~r/\A<\/a2ui-json\s*\z/u, rest)

  # -- cleaning -----------------------------------------------------------------------

  @doc false
  # Trims a block or a text and drops one Markdown code fence around it.
  @spec clean(String.t()) :: String.t()
  def clean(text) do
    text
    |> String.trim()
    |> String.replace(~r/\A```[a-zA-Z-]*\s*/u, "", global: false)
    |> String.replace(~r/\s*```[a-zA-Z-]*\z/u, "", global: false)
    |> String.trim()
  end

  @doc false
  @spec open_tag_re() :: Regex.t()
  def open_tag_re, do: ~r/<a2ui-json(?:\s[^>]*)?>/iu

  @doc false
  @spec close_tag_re() :: Regex.t()
  def close_tag_re, do: ~r/<\/a2ui-json\s*>/iu

  defp close_tag_at_start_re, do: ~r/\A<\/a2ui-json\s*>/iu

  defp slice(content, from), do: binary_part(content, from, byte_size(content) - from)

  defp parse_error(message), do: Error.new(:parse, "PARSE_ERROR", message)
end

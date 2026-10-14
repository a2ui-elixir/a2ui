defmodule A2UIAgent.A2A do
  @moduledoc """
  The A2UI extension of the [A2A protocol](https://a2a-protocol.org):
  extension URIs and their negotiation, and A2UI messages carried in A2A
  parts.

  Parts are the JSON objects of A2A's JSON-RPC binding:

      %{"kind" => "text", "text" => "Here is your form."}
      %{"kind" => "data", "data" => message, "metadata" => %{"mimeType" => "application/a2ui+json"}}

  Each A2UI message travels in a data part of its own, the shape the
  reference SDKs, sample agents and clients exchange. `a2ui_messages/1`
  also reads a data part whose `data` is a list of messages, the shape
  the extension specification describes.

  `A2UIAgent.A2A.Server` answers A2A requests with these helpers, and
  `A2UIAgent.A2A.Plug` serves them over HTTP.
  """

  require Logger

  alias A2UICore.{Error, SemVer}

  @moduledoc since: "0.1.0"

  @mime_type "application/a2ui+json"
  @deprecated_mime_type "application/json+a2ui"
  @extension_base_uri "https://a2ui.org/a2a-extension/a2ui"
  @extension_description "Provides agent driven UI using the A2UI JSON format."

  @typedoc "An A2A part, as a JSON object."
  @type part :: %{String.t() => term()}

  @doc "The MIME type that marks a data part as A2UI."
  @spec mime_type() :: String.t()
  def mime_type, do: @mime_type

  @doc """
  The MIME type for parts of a protocol version: `"application/a2ui+json"`
  from v0.9.1 on, the older `"application/json+a2ui"` before it and when
  the version is unknown (`nil`).
  """
  @spec mime_type(String.t() | nil) :: String.t()
  def mime_type(nil), do: @deprecated_mime_type

  def mime_type(version) when is_binary(version) do
    case SemVer.to_semver(version) do
      {:ok, parsed} ->
        if SemVer.compare(parsed, "0.9.1") < 0, do: @deprecated_mime_type, else: @mime_type

      :error ->
        @mime_type
    end
  end

  # -- extension ----------------------------------------------------------------------

  @doc "The URI every A2UI extension URI starts with."
  @spec extension_base_uri() :: String.t()
  def extension_base_uri, do: @extension_base_uri

  @doc """
  The extension URI of a version, for example
  `"https://a2ui.org/a2a-extension/a2ui/v1.0"` for `"1.0"` or `"v1.0"`.
  """
  @spec extension_uri(String.t()) :: String.t()
  def extension_uri(version) when is_binary(version),
    do: "#{@extension_base_uri}/v#{String.trim_leading(version, "v")}"

  @doc "The version an A2UI extension URI names, or `nil` for any other URI."
  @spec extension_version(String.t()) :: String.t() | nil
  def extension_version(@extension_base_uri <> "/v" <> version) when version != "", do: version
  def extension_version(_uri), do: nil

  @doc """
  The A2UI entry for an agent card's `capabilities.extensions`.

  Options: `:accepts_inline_catalogs` (default `false`) and
  `:supported_catalog_ids` (default `[]`). Each appears in `params` only
  when it differs from its default, and `params` only when it is not
  empty.
  """
  @spec agent_extension(String.t(), keyword()) :: map()
  def agent_extension(version, options \\ []) do
    params =
      %{}
      |> put_if(Keyword.get(options, :accepts_inline_catalogs, false), "acceptsInlineCatalogs")
      |> put_unless_empty("supportedCatalogIds", Keyword.get(options, :supported_catalog_ids, []))

    %{"uri" => extension_uri(version), "description" => @extension_description}
    |> put_unless_empty("params", params)
  end

  defp put_if(map, true, key), do: Map.put(map, key, true)
  defp put_if(map, _value, _key), do: map

  defp put_unless_empty(map, _key, empty) when empty in [[], %{}, nil], do: map
  defp put_unless_empty(map, key, value), do: Map.put(map, key, value)

  @doc "The A2UI extension URIs an agent card advertises."
  @spec advertised_extensions(map()) :: [String.t()]
  def advertised_extensions(%{"capabilities" => %{"extensions" => extensions}})
      when is_list(extensions) do
    for %{"uri" => uri} <- extensions, a2ui_extension?(uri), uniq: true, do: uri
  end

  def advertised_extensions(_card), do: []

  @doc """
  The A2UI extension URIs among `values`: extension URIs, or
  comma-separated lists of them as the `X-A2A-Extensions` header carries.
  """
  @spec requested_extensions([term()]) :: [String.t()]
  def requested_extensions(values) when is_list(values) do
    for value <- values,
        is_binary(value),
        uri <- String.split(value, ","),
        uri = String.trim(uri),
        a2ui_extension?(uri),
        uniq: true,
        do: uri
  end

  defp a2ui_extension?(uri), do: is_binary(uri) and String.starts_with?(uri, @extension_base_uri)

  @doc """
  The newest extension URI that is both requested and advertised, or
  `nil`. Versions compare as SemVer, so `v1.10.0` is newer than `v1.2.0`.
  """
  @spec select_newest([String.t()], [String.t()]) :: String.t() | nil
  def select_newest(requested, advertised) do
    case Enum.filter(requested, &(&1 in advertised)) do
      [] -> nil
      matched -> Enum.max(matched, &(SemVer.compare(version_of(&1), version_of(&2)) >= 0))
    end
  end

  defp version_of(uri), do: extension_version(uri) || uri

  @doc """
  Activates the newest A2UI extension that is both requested and
  advertised: `{:ok, uri, version}`, or `:none`.
  """
  @spec activate([String.t()], [String.t()]) :: {:ok, String.t(), String.t()} | :none
  def activate(requested, advertised) do
    case select_newest(requested, advertised) do
      nil -> :none
      uri -> {:ok, uri, version_of(uri)}
    end
  end

  # -- parts --------------------------------------------------------------------------

  @doc """
  A data part holding `data` (an A2UI message, or a list of them), marked
  with the MIME type of `version` (see `mime_type/1`).
  """
  @spec a2ui_part(map() | [map()], String.t() | nil) :: part()
  def a2ui_part(data, version) when is_map(data) or is_list(data) do
    %{"kind" => "data", "data" => data, "metadata" => %{"mimeType" => mime_type(version)}}
  end

  @doc "A text part."
  @spec text_part(String.t()) :: part()
  def text_part(text) when is_binary(text), do: %{"kind" => "text", "text" => text}

  @doc """
  Whether `part` is a data part marked as A2UI, with either MIME type in
  its metadata.
  """
  @spec a2ui_part?(term()) :: boolean()
  def a2ui_part?(%{"data" => _data, "metadata" => %{"mimeType" => type}} = part),
    do: type in [@mime_type, @deprecated_mime_type] and Map.get(part, "kind", "data") == "data"

  def a2ui_part?(_part), do: false

  @doc """
  The A2UI messages that `parts` carry, in order. A data part may hold one
  message or a list of them.

  The MIME type may also be a property of the part itself rather than of
  its metadata, as some sample clients send it.
  """
  @spec a2ui_messages([term()]) :: [map()]
  def a2ui_messages(parts) when is_list(parts), do: Enum.flat_map(parts, &part_messages/1)

  defp part_messages(part) do
    if a2ui_part?(part) or a2ui_part?(lift_mime_type(part)),
      do: for(message <- List.wrap(part["data"]), is_map(message), do: message),
      else: []
  end

  defp lift_mime_type(%{"mimeType" => type} = part),
    do: Map.put(part, "metadata", %{"mimeType" => type})

  defp lift_mime_type(part), do: part

  @doc """
  The A2A parts for parsed response parts (`{:text, text}` and
  `{:a2ui, messages}`): a text part for each non-empty text and a data
  part for each message.
  """
  @spec to_parts([{:text, String.t()} | {:a2ui, [map()]}], String.t() | nil) :: [part()]
  def to_parts(parsed, version) do
    Enum.flat_map(parsed, fn
      {:text, ""} -> []
      {:text, text} -> [text_part(text)]
      {:a2ui, messages} -> Enum.map(messages, &a2ui_part(&1, version))
    end)
  end

  @doc """
  Parses a complete model response with `parser` (a format parser, see
  `A2UIAgent.RequestProcessor.parser/1`) into A2A parts.

  A response that does not parse is logged and yields no parts. Option:
  `:fallback_text` — the text part to answer with when there are no
  parts, for example the response itself.
  """
  @spec response_parts(struct(), String.t(), String.t() | nil, keyword()) :: [part()]
  def response_parts(%parser_module{} = parser, content, version, options \\ []) do
    parts =
      case parser_module.parse_response(parser, content, []) do
        {:ok, parsed} ->
          to_parts(parsed, version)

        {:error, error} ->
          Logger.warning("Failed to parse A2UI response: #{Exception.message(error)}")
          []
      end

    case {parts, options[:fallback_text]} do
      {[], fallback} when is_binary(fallback) and fallback != "" -> [text_part(fallback)]
      _ -> parts
    end
  end

  @doc """
  Reads the next chunk of a streamed response with `parser` and returns
  the A2A parts it completes, with the parser to read the next chunk.
  """
  @spec chunk_parts(struct(), String.t(), String.t() | nil) ::
          {:ok, struct(), [part()]} | {:error, Error.t()}
  def chunk_parts(%parser_module{} = parser, chunk, version) do
    with {:ok, parser, parsed} <- parser_module.parse_chunk(parser, chunk, []) do
      {:ok, parser, to_parts(parsed, version)}
    end
  end
end

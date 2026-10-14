defmodule A2UIAgent.CatalogProvider do
  @moduledoc """
  Loads catalog documents into `A2UICore.Catalog`s.

      {:ok, catalog} = A2UIAgent.CatalogProvider.load_file("priv/catalogs/basic.json")

      {:ok, catalog} =
        A2UIAgent.CatalogProvider.load_document(document,
          catalog_id: "acme/forms",
          protocol_version: "v1.0"
        )

  Both functions take `:catalog_id` and `:protocol_version`. Each one
  supplies what the document omits and must agree with what the document
  states: a document that declares `"catalogId": "a"` read with
  `catalog_id: "b"` is an error, since one of the two is wrong. When
  neither the document nor the options name the catalog or its protocol
  version, loading fails, because nothing else can.

  Every failure is an `A2UICore.Error` of category `:catalog`.
  """

  alias A2UICore.{Catalog, Error, Version}

  @moduledoc since: "0.1.0"

  @typedoc "`:catalog_id` and `:protocol_version`, both optional."
  @type option :: {:catalog_id, String.t()} | {:protocol_version, String.t()}

  @doc """
  Reads a catalog document from a filesystem path or a `file://` URL.

  The file must hold a JSON object.
  """
  @spec load_file(String.t(), [option()]) :: {:ok, Catalog.t()} | {:error, Error.t()}
  def load_file(path, options \\ []) when is_binary(path) do
    with {:ok, local} <- local_path(path),
         {:ok, text} <- read(local, path),
         {:ok, document} <- decode(text, path) do
      load(document, options, "'#{path}'")
    end
  end

  @doc """
  Loads a catalog from a decoded catalog document.
  """
  @spec load_document(term(), [option()]) :: {:ok, Catalog.t()} | {:error, Error.t()}
  def load_document(document, options \\ [])

  def load_document(document, options) when is_map(document),
    do: load(document, options, "The in-memory catalog document")

  def load_document(_document, _options),
    do: {:error, catalog_error("The in-memory catalog document is not a mapping.")}

  @doc """
  Like `load_file/2`, raising `A2UICore.Error` on failure.
  """
  @spec load_file!(String.t(), [option()]) :: Catalog.t()
  def load_file!(path, options \\ []), do: unwrap!(load_file(path, options))

  @doc """
  Like `load_document/2`, raising `A2UICore.Error` on failure.
  """
  @spec load_document!(term(), [option()]) :: Catalog.t()
  def load_document!(document, options \\ []), do: unwrap!(load_document(document, options))

  defp load(document, options, source) do
    with {:ok, catalog_id} <- settle_catalog_id(document, options[:catalog_id], source),
         {:ok, version} <- settle_version(document, options[:protocol_version], source) do
      document
      |> Map.put("catalogId", catalog_id)
      |> Catalog.from_json(catalog_id: catalog_id, protocol_version: version)
    end
  end

  # -- reading ------------------------------------------------------------------

  # A single-letter scheme is a Windows drive (`C:/catalogs/x.json`), not
  # a URL.
  defp local_path(path) do
    case URI.parse(path) do
      %URI{scheme: nil} ->
        {:ok, path}

      %URI{scheme: <<letter>>} when letter in ?a..?z or letter in ?A..?Z ->
        {:ok, path}

      %URI{scheme: "file", path: file_path} ->
        {:ok, URI.decode(file_path || "")}

      %URI{scheme: scheme} ->
        {:error, catalog_error("Unsupported catalog URL scheme '#{scheme}' in '#{path}'.")}
    end
  end

  defp read(local, path) do
    case File.read(local) do
      {:ok, text} ->
        {:ok, text}

      {:error, reason} ->
        {:error,
         catalog_error(
           "Cannot read the catalog document '#{path}': #{:file.format_error(reason)}"
         )}
    end
  end

  defp decode(text, path) do
    case Jason.decode(text) do
      {:ok, document} when is_map(document) ->
        {:ok, document}

      {:ok, _other} ->
        {:error, catalog_error("The catalog document '#{path}' is not a JSON object.")}

      {:error, error} ->
        {:error,
         catalog_error(
           "The catalog document '#{path}' is not valid JSON: #{Exception.message(error)}"
         )}
    end
  end

  # -- settling id and version ---------------------------------------------------

  defp settle_catalog_id(_document, provided, _source)
       when not is_nil(provided) and (not is_binary(provided) or provided == ""),
       do: {:error, catalog_error("Provider 'catalog_id' must be a non-empty string.")}

  defp settle_catalog_id(document, provided, source) do
    case Map.get(document, "catalogId") do
      nil when is_nil(provided) ->
        {:error,
         catalog_error(
           "#{source} declares no 'catalogId' and the provider was given none, so " <>
             "nothing names the catalog."
         )}

      nil ->
        {:ok, provided}

      declared when not is_binary(declared) or declared == "" ->
        {:error,
         catalog_error("#{source} declares a 'catalogId' that is not a non-empty string.")}

      declared when is_nil(provided) or declared == provided ->
        {:ok, declared}

      declared ->
        {:error,
         catalog_error(
           "#{source} declares catalog id '#{declared}', but the provider was given " <>
             "'#{provided}'."
         )}
    end
  end

  defp settle_version(document, provided, source) do
    with {:ok, provided} <- provided_version(provided) do
      case Map.get(document, "protocolVersion") do
        nil when is_nil(provided) ->
          {:error,
           catalog_error(
             "#{source} declares no 'protocolVersion' and the provider was given none, " <>
               "so nothing states which protocol it is written against."
           )}

        nil ->
          {:ok, provided}

        declared ->
          declared_version(declared, provided, source)
      end
    end
  end

  defp provided_version(nil), do: {:ok, nil}

  defp provided_version(version) do
    case supported_version(version) do
      {:ok, canonical} ->
        {:ok, canonical}

      :error ->
        {:error,
         catalog_error("Provider was given invalid protocol version '#{inspect(version)}'.")}
    end
  end

  defp declared_version(declared, _provided, source)
       when not is_binary(declared) or declared == "",
       do:
         {:error,
          catalog_error("#{source} declares a 'protocolVersion' that is not a non-empty string.")}

  defp declared_version(declared, provided, source) do
    case supported_version(declared) do
      {:ok, canonical} when is_nil(provided) or canonical == provided ->
        {:ok, canonical}

      {:ok, _canonical} ->
        {:error,
         catalog_error(
           "#{source} declares protocol version '#{declared}', but the provider was " <>
             "given '#{provided}'."
         )}

      :error ->
        {:error, catalog_error("#{source} declares unsupported protocol version '#{declared}'.")}
    end
  end

  defp supported_version(version) do
    case Version.to_protocol_version(version) do
      {:ok, canonical} -> if canonical in Version.supported(), do: {:ok, canonical}, else: :error
      :error -> :error
    end
  end

  defp catalog_error(message), do: Error.new(:catalog, "CATALOG_ERROR", message)

  defp unwrap!({:ok, value}), do: value
  defp unwrap!({:error, error}), do: raise(error)
end

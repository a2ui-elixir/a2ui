defmodule A2UIAgent.CatalogResolver do
  @moduledoc """
  Negotiates the catalogs that are active for one renderer.

  A renderer sends its capabilities keyed by protocol version, for
  example `%{"v1.0" => %{"supportedCatalogIds" => [...], "inlineCatalogs" => [...]}}`.
  `resolve/3` returns the agent's catalogs that the renderer names, in the
  renderer's order of preference, ignoring ids the agent does not hold.

  When the agent accepts inline catalogs, each inline catalog becomes an
  active catalog of its own after the registered ones, unless an active
  catalog already has its id. Otherwise inline catalogs are dropped, but
  they are still checked, since a malformed one makes the capabilities
  malformed whether or not the agent uses it.

  Registered catalogs resolve to their transformed form; inline catalogs
  are not transformed.
  """

  alias A2UIAgent.{CatalogConfig, Catalogs}
  alias A2UICore.{Catalog, Error}

  @moduledoc since: "0.1.0"

  @entry_keys ["supportedCatalogIds", "inlineCatalogs"]

  @doc """
  Returns the active catalogs.

  `capabilities` of `nil` (a request that carries none) activates every
  registered catalog in registration order. Option:
  `:accepts_inline_catalogs` (default `false`).

  Errors:

    * `:catalog` — capabilities are given and no catalog is active (the
      renderer names none of the registered catalogs, or none are
      registered); `inlineCatalogs` is not a list of catalog objects, or
      an inline catalog has no non-empty `catalogId`; the registered
      catalogs span protocol versions that read different capabilities
      entries;
    * `:validation` — the capabilities have no valid entry for the
      registered catalogs' protocol version.
  """
  @spec resolve([CatalogConfig.t()], map() | nil, keyword()) ::
          {:ok, [Catalog.t()]} | {:error, Error.t()}
  def resolve(configs, capabilities, options \\ [])

  def resolve(configs, nil, _options) do
    pristine = Enum.map(configs, & &1.catalog)
    {:ok, configs |> Enum.map(& &1.transformed) |> Catalog.link_catalogs(pristine)}
  end

  def resolve([], _capabilities, _options),
    do:
      {:error,
       catalog_error(
         "No catalogs are registered, so none of the renderer's catalogs can be resolved."
       )}

  def resolve(configs, capabilities, options) do
    registered = Enum.map(configs, & &1.transformed)

    with {:ok, key, version} <- capabilities_key(registered),
         {:ok, entry} <- entry(capabilities, key),
         {:ok, inline} <- inline_catalogs(entry, key, version) do
      inline = if options[:accepts_inline_catalogs], do: inline, else: []

      # Inactive registered catalogs stay resolvable as peers, and so do the
      # unpruned catalogs transformers start from; inline catalogs are peers
      # only when active. Linking returns per-request copies.
      with {:ok, active} <- activate(registered, entry["supportedCatalogIds"], inline) do
        pristine = Enum.map(configs, & &1.catalog)
        {:ok, Catalog.link_catalogs(active, pristine ++ registered)}
      end
    end
  end

  defp activate(registered, supported_ids, inline) do
    by_id = Enum.reduce(registered, %{}, fn c, acc -> Map.put_new(acc, c.catalog_id, c) end)

    active =
      supported_ids
      |> Enum.uniq()
      |> Enum.flat_map(fn id -> if by_id[id], do: [by_id[id]], else: [] end)

    active =
      Enum.reduce(inline, active, fn catalog, active ->
        if Enum.any?(active, &(&1.catalog_id == catalog.catalog_id)),
          do: active,
          else: active ++ [catalog]
      end)

    case active do
      [] ->
        ids = registered |> Enum.map(& &1.catalog_id) |> Enum.uniq()

        {:error,
         catalog_error(
           "No client-supported catalog found on the agent side. Agent-supported " <>
             "catalogs are: #{inspect(ids)}"
         )}

      active ->
        {:ok, active}
    end
  end

  # v0.9 and v0.9.1 catalogs both read the "v0.9" entry.
  defp capabilities_key([first | rest]) do
    key = key_of(first)

    case Enum.find(rest, &(key_of(&1) != key)) do
      nil ->
        {:ok, key, first.protocol_version}

      other ->
        {:error,
         catalog_error(
           "The registered catalogs read different capabilities entries: " <>
             "'#{first.catalog_id}' reads '#{key}' and '#{other.catalog_id}' reads " <>
             "'#{key_of(other)}'."
         )}
    end
  end

  defp key_of(%Catalog{} = catalog) do
    case Catalogs.protocol_version(catalog) do
      "v0.9.1" -> "v0.9"
      canonical -> canonical
    end
  end

  defp entry(capabilities, _key) when not is_map(capabilities),
    do: {:error, validation_error("Renderer capabilities must be a mapping.")}

  defp entry(capabilities, key) do
    case Map.get(capabilities, key) do
      nil ->
        {:error,
         validation_error(
           "The renderer capabilities have no '#{key}' entry, which the registered " <>
             "catalogs read."
         )}

      entry ->
        check_entry(entry, key)
    end
  end

  defp check_entry(entry, key) when not is_map(entry),
    do: {:error, validation_error("Invalid '#{key}' renderer capabilities: not an object.")}

  defp check_entry(entry, key) do
    extra = Map.keys(entry) -- @entry_keys
    ids = entry["supportedCatalogIds"]

    cond do
      extra != [] ->
        {:error,
         validation_error(
           "Invalid '#{key}' renderer capabilities: extra inputs are not permitted " <>
             "(#{Enum.join(extra, ", ")})."
         )}

      not is_list(ids) or not Enum.all?(ids, &is_binary/1) ->
        {:error,
         validation_error(
           "Invalid '#{key}' renderer capabilities: 'supportedCatalogIds' must be a list " <>
             "of strings."
         )}

      true ->
        {:ok, entry}
    end
  end

  defp inline_catalogs(entry, key, version) do
    case Map.get(entry, "inlineCatalogs") do
      nil ->
        {:ok, []}

      documents when is_list(documents) ->
        documents
        |> Enum.with_index()
        |> Enum.reduce_while({:ok, []}, &collect_inline(&1, &2, key, version))
        |> then(fn
          {:ok, catalogs} -> {:ok, Enum.reverse(catalogs)}
          error -> error
        end)

      _other ->
        {:error,
         catalog_error("Invalid inline catalog in '#{key}' renderer capabilities: not a list.")}
    end
  end

  defp collect_inline({document, index}, {:ok, acc}, key, version) do
    case inline_catalog(document, index, key, version) do
      {:ok, catalog} -> {:cont, {:ok, [catalog | acc]}}
      {:error, error} -> {:halt, {:error, error}}
    end
  end

  defp inline_catalog(%{"catalogId" => id} = document, _index, _key, version)
       when is_binary(id) do
    Catalog.from_json(document, protocol_version: version)
  end

  defp inline_catalog(document, index, key, _version) do
    problem =
      if is_map(document),
        do: "has no string 'catalogId'",
        else: "is not an object"

    {:error,
     catalog_error(
       "Invalid inline catalog in '#{key}' renderer capabilities: entry #{index} #{problem}."
     )}
  end

  defp catalog_error(message), do: Error.new(:catalog, "CATALOG_ERROR", message)
  defp validation_error(message), do: Error.new(:validation, "VALIDATION_FAILED", message)
end

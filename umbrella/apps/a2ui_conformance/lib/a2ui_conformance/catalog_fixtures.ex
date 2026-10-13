defmodule A2UIConformance.CatalogFixtures do
  @moduledoc false

  # Builds the catalogs a conformance case runs against (reference
  # harness `get_catalogs_for_test_case`, L221-473).
  #
  # A case names catalogs in several ways — an inline `catalog` /
  # `catalogs` entry, `catalogPaths` into the reference checkout, or
  # implicitly through the `catalogId` of a `createSurface` message — and
  # the alias ids `basic`, `standard`, `v0.9:basic`, `v1.0:basic` are
  # always available. The first catalog of the result is the one a case
  # without further information uses (`evaluate_function` takes it).

  alias A2UIConformance.{Case, Registry}
  alias A2UICore.Catalog
  alias A2UICore.Catalog.Basic
  alias A2UICore.Error
  alias A2UICore.Version

  @capability_actions ["get_client_capabilities", "get_renderer_capabilities"]
  @basic_ids [
    "https://a2ui.org/specification/v0_9/catalogs/basic/catalog.json",
    "https://a2ui.org/specification/v1_0/catalogs/basic/catalog.json"
  ]

  @doc """
  The catalogs for a case, or the `A2UICore.Error` raised while
  building one of them.
  """
  @spec for_case(Case.t()) :: {:ok, [Catalog.t()]} | {:error, Error.t()}
  def for_case(%Case{raw: raw, protocol_version: version} = test_case) do
    version = version || "v0.9"
    v09 = Basic.catalog("v0.9")
    v10 = Basic.catalog("v1.0")
    current = if version == "v1.0", do: v10, else: v09

    state = %{
      catalogs: seed(v09, v10, version),
      specified: [],
      version: version,
      current: current,
      v09: v09,
      v10: v10,
      case: test_case
    }

    with {:ok, state} <- inline_catalog(state, raw["catalog"]),
         {:ok, state} <- inline_catalogs(state, raw["catalogs"]),
         {:ok, state} <- catalog_paths(state, raw["catalogPaths"]) do
      state = implied_catalogs(state, raw)
      {:ok, ordered(state, raw["action"])}
    end
  end

  # -- seeds --------------------------------------------------------------------

  # The alias table only depends on whether the case is v1.0. The pieces
  # that are costly to assemble carry no function implementations, so they
  # are cached as data; implementations are attached per call.
  defp seed(v09, v10, version) do
    aliases = aliases()
    basic = if version == "v1.0", do: Basic.implement(aliases.basic_v1, "v1.0"), else: v09

    []
    |> put(v09.catalog_id, v09)
    |> put(v10.catalog_id, v10)
    |> put("basic", basic)
    |> put("standard", aliases.standard)
    |> put("v0.9:basic", v09)
    |> put("v1.0:basic", v10)
  end

  defp aliases do
    key = {__MODULE__, :aliases}

    case :persistent_term.get(key, :missing) do
      :missing ->
        v09 = Basic.declared("v0.9")

        aliases = %{
          standard: assembled!("standard", "v0.9", v09),
          basic_v1: Catalog.derive(Basic.declared("v1.0"), "basic")
        }

        :persistent_term.put(key, aliases)
        aliases

      aliases ->
        aliases
    end
  end

  # An insertion-ordered keyed list: replacing a key keeps its position.
  defp put(catalogs, key, catalog) do
    if List.keymember?(catalogs, key, 0),
      do: List.keyreplace(catalogs, key, 0, {key, catalog}),
      else: catalogs ++ [{key, catalog}]
  end

  # -- explicit catalogs --------------------------------------------------------

  defp inline_catalog(state, %{"catalogSchema" => schema}) when is_map(schema) do
    id = catalog_id(state.case.raw) || "catalog-#{state.case.name}"

    with {:ok, catalog} <-
           Catalog.from_json(schema, catalog_id: id, protocol_version: state.version) do
      {:ok, register(state, id, catalog)}
    end
  end

  defp inline_catalog(state, %{} = spec) do
    if Map.has_key?(spec, "components") or Map.has_key?(spec, "catalogId") do
      id = spec["catalogId"] || catalog_id(state.case.raw) || "catalog-#{state.case.name}"
      build_described(state, id, state.version, spec, true)
    else
      {:ok, state}
    end
  end

  defp inline_catalog(state, _other), do: {:ok, state}

  defp inline_catalogs(state, items) when is_list(items) do
    Enum.reduce_while(items, {:ok, state}, fn item, {:ok, state} ->
      case inline_item(state, item) do
        {:ok, state} -> {:cont, {:ok, state}}
        {:error, _error} = error -> {:halt, error}
      end
    end)
  end

  defp inline_catalogs(state, _other), do: {:ok, state}

  defp inline_item(state, %{"catalogSchema" => %{} = schema} = item) do
    id = schema["catalogId"] || item["catalogId"]
    version = item["protocolVersion"] || schema["protocolVersion"] || "v0.9"

    if id do
      with {:ok, catalog} <- Catalog.from_json(schema, catalog_id: id, protocol_version: version) do
        {:ok, register(state, id, catalog)}
      end
    else
      {:ok, state}
    end
  end

  defp inline_item(state, %{"catalogId" => id} = item) do
    build_described(state, id, item["protocolVersion"] || state.version, item, false)
  end

  defp inline_item(state, _item), do: {:ok, state}

  # A catalog described by `components` / `theme` / `functions`, or an id
  # alone (all basic components, none under capability actions).
  defp build_described(state, id, version, spec, with_function_stub?) do
    components = spec["components"]
    theme = spec["theme"]
    functions = spec["functions"]

    if truthy?(components) or truthy?(theme) or truthy?(functions) do
      document =
        %{"catalogId" => id}
        |> put_if(with_function_stub? and not truthy?(functions), "$defs", %{
          "anyFunction" => %{"not" => %{}}
        })
        |> put_if(truthy?(components), "components", components)
        |> put_if(truthy?(theme), "theme", theme)
        |> put_if(truthy?(functions), "functions", functions)

      with {:ok, catalog} <-
             Catalog.from_json(document, catalog_id: id, protocol_version: version) do
        {:ok, register(state, id, catalog)}
      end
    else
      source =
        if state.case.raw["action"] in @capability_actions,
          do: %{state.v09 | components: %{}},
          else: state.v09

      with {:ok, catalog} <- assembled(id, version, source) do
        {:ok, register(state, id, catalog)}
      end
    end
  end

  defp put_if(map, true, key, value), do: Map.put(map, key, value)
  defp put_if(map, false, _key, _value), do: map

  defp truthy?(value), do: value not in [nil, false, "", [], %{}]

  defp register(state, id, catalog) do
    %{state | catalogs: put(state.catalogs, id, catalog), specified: state.specified ++ [catalog]}
  end

  # -- catalogPaths -------------------------------------------------------------

  defp catalog_paths(state, paths) when is_list(paths) do
    Enum.reduce_while(paths, {:ok, state}, fn path, {:ok, state} ->
      case load_path(state, path) do
        {:ok, state} -> {:cont, {:ok, state}}
        {:error, _error} = error -> {:halt, error}
      end
    end)
  end

  defp catalog_paths(state, _other), do: {:ok, state}

  defp load_path(state, path) do
    full = Path.join(Registry.reference_root(), path)

    unless File.exists?(full) do
      raise ArgumentError,
            "catalogPaths entry '#{path}' does not exist (resolved to #{full})"
    end

    document = full |> File.read!() |> Jason.decode!()
    id = document["catalogId"] || document["id"] || "test-catalog"

    if id in @basic_ids or String.contains?(path, "basic/catalog.json") do
      matching = if String.contains?(state.version, "1.0"), do: state.v10, else: state.v09

      {:ok,
       %{
         state
         | catalogs: put(state.catalogs, id, matching),
           specified: state.specified ++ [matching]
       }}
    else
      load_custom(state, document, id)
    end
  end

  defp load_custom(state, document, id) do
    with {:ok, catalog} <-
           Catalog.from_json(document, catalog_id: id, protocol_version: state.version) do
      state = %{state | specified: state.specified ++ [catalog]}
      if id == "test-catalog", do: {:ok, state}, else: add_test_alias(state, document)
    end
  end

  # A custom catalog is also reachable under the `test-catalog` alias.
  defp add_test_alias(state, document) do
    with {:ok, alias_catalog} <-
           Catalog.from_json(document,
             catalog_id: "test-catalog",
             protocol_version: state.version
           ) do
      {:ok,
       %{
         state
         | catalogs: put(state.catalogs, "test-catalog", alias_catalog),
           specified: state.specified ++ [alias_catalog]
       }}
    end
  end

  # -- catalogs implied by messages ---------------------------------------------

  defp implied_catalogs(state, raw) do
    expected = raw["expectError"] || raw["expect_error"]

    catalog_error? =
      is_map(expected) and expected["category"] in ["CatalogError", "A2uiCatalogError"]

    messages = collect_messages(raw)

    {state, _version} =
      scan(messages, state, nil, catalog_error?)

    state
  end

  defp collect_messages(raw) do
    base =
      cond do
        truthy?(raw["messages"]) -> raw["messages"]
        Map.has_key?(raw, "payload") -> [raw["payload"]]
        true -> []
      end

    steps =
      for step <- List.wrap(raw["steps"]),
          is_map(step),
          messages = step["messages"] || step["payload"],
          truthy?(messages),
          item <- List.wrap(messages),
          do: item

    List.wrap(base) ++ steps
  end

  defp scan(items, state, version, catalog_error?) when is_list(items) do
    Enum.reduce(items, {state, version}, fn item, {state, version} ->
      scan(item, state, version, catalog_error?)
    end)
  end

  defp scan(%{} = item, state, version, catalog_error?) do
    version = if is_binary(item["version"]), do: item["version"], else: version

    {state, version} =
      if Map.has_key?(item, "messages"),
        do: scan(item["messages"], state, version, catalog_error?),
        else: {state, version}

    if catalog_error?,
      do: {state, version},
      else: {declared_catalogs(item, state, version), version}
  end

  defp scan(_other, state, version, _catalog_error?), do: {state, version}

  # A surface-creation message names the catalog it wants.
  defp declared_catalogs(item, state, version) do
    Enum.reduce(["createSurface", "beginRendering"], state, fn key, state ->
      case item[key] do
        %{"catalogId" => id} -> add_catalog_id(state, id, version)
        _other -> state
      end
    end)
  end

  defp add_catalog_id(state, id, version) when is_binary(id) and id != "" do
    known? = List.keymember?(state.catalogs, id, 0)
    carried? = Enum.any?(state.catalogs, fn {_key, catalog} -> catalog.catalog_id == id end)

    if known? and carried? do
      state
    else
      catalog =
        case assembled(id, normalize(version) || state.version, state.current) do
          {:ok, catalog} -> catalog
          {:error, _unsupported_version} -> assembled!(id, state.version, state.current)
        end

      %{state | catalogs: put(state.catalogs, id, catalog)}
    end
  end

  defp add_catalog_id(state, _id, _version), do: state

  # A catalog made of another catalog's components and none of its
  # functions. It keeps the definitions those components' schemas refer
  # to, so they still resolve.
  defp assembled(id, version, %Catalog{} = source) do
    Catalog.new(id, version,
      components: Map.values(source.components),
      defs: Map.drop(source.defs, ["anyComponent", "anyFunction"])
    )
  end

  defp assembled!(id, version, source) do
    {:ok, catalog} = assembled(id, version, source)
    catalog
  end

  defp normalize(nil), do: nil

  defp normalize(version) do
    case Version.to_protocol_version(version) do
      {:ok, protocol} -> protocol
      :error -> version
    end
  end

  # -- result -------------------------------------------------------------------

  defp ordered(state, action) do
    if action in @capability_actions and state.specified != [] do
      state.specified
    else
      rest =
        for {_key, catalog} <- state.catalogs,
            catalog not in state.specified,
            catalog != state.current,
            do: catalog

      state.specified ++ [state.current] ++ rest
    end
  end

  @doc """
  The case's catalog id (`resolve_catalog_id`, harness L162-171): its own
  `catalogId`, else the one of `catalog` or `catalog.catalogSchema`.
  """
  @spec catalog_id(map()) :: String.t() | nil
  def catalog_id(raw) do
    spec = if is_map(raw["catalog"]), do: raw["catalog"], else: %{}
    schema = if is_map(spec["catalogSchema"]), do: spec["catalogSchema"], else: %{}
    raw["catalogId"] || spec["catalogId"] || schema["catalogId"]
  end
end

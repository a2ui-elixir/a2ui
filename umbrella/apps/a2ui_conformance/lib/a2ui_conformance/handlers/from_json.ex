defmodule A2UIConformance.Handlers.FromJson do
  @moduledoc false

  # `from_json` (reference harness `validate_from_json_case`): builds a
  # catalog from a catalog document (inline, or `catalogPath` into the
  # reference checkout), links the peers of `peerCatalogPaths`, and checks
  # what the case expects of it: id and protocol version, that listed
  # components and functions exist, that its validation schema is
  # self-contained, that it matches the library's own implementation of
  # the catalog (`matchesBuiltinCatalog`), and that listed component
  # payloads validate (or fail). An unknown `expect` key fails the case.

  @behaviour A2UIConformance.Handler

  import ExUnit.Assertions

  alias A2UIConformance.{Case, CaseCatalog, CatalogFixtures, Matchers}
  alias A2UICore.{Catalog, SemVer}
  alias A2UICore.Validation.Payload

  @expect_keys ~w(catalogId components functions invalidComponents matchesBuiltinCatalog
                  protocolVersion selfContained theme validComponents)

  # Every component carries these fields; `matchesBuiltinCatalog` leaves
  # them out when it compares component shapes.
  @envelope_fields ["id", "component"]

  @impl true
  def run(%Case{raw: raw, protocol_version: version}, _context) do
    schema = CaseCatalog.document(raw)

    catalog_id =
      CatalogFixtures.catalog_id(raw) ||
        if(raw["catalogPath"], do: CaseCatalog.plain(schema)["catalogId"])

    result = Catalog.from_json(schema, catalog_id: catalog_id, protocol_version: version)

    case {result, raw["expectError"]} do
      {{:error, error}, expected} when not is_nil(expected) ->
        Matchers.assert_error(expected, error)
        :ok

      {{:ok, _catalog}, expected} when not is_nil(expected) ->
        flunk("expected #{inspect(expected)}, but the catalog loaded")

      {{:error, error}, nil} ->
        flunk("catalog failed to load: #{Exception.message(error)}")

      {{:ok, catalog}, nil} ->
        catalog |> CaseCatalog.with_peers(raw) |> check(raw["expect"] || %{})
        :ok
    end
  end

  defp check(catalog, expected) do
    unknown = Map.keys(expected) -- @expect_keys
    assert unknown == [], "Unknown from_json expect keys: #{inspect(Enum.sort(unknown))}"

    if id = expected["catalogId"], do: assert(catalog.catalog_id == id)
    if version = expected["protocolVersion"], do: assert(catalog.protocol_version == version)

    expected_names(expected["components"], &Catalog.get_component(catalog, &1), "component")

    expected_names(
      list_only(expected["functions"]),
      &Catalog.get_function(catalog, &1),
      "function"
    )

    if expected["selfContained"], do: assert_self_contained(Catalog.validation_schema(catalog))
    if expected["matchesBuiltinCatalog"], do: assert_matches_builtin(catalog)
    check_payloads(catalog, expected)
  end

  # The loaded catalog is equivalent to the library's own implementation
  # of the catalog with its id: the same id and protocol version, the
  # same property and required names for each component, and the same
  # signature for each function.
  defp assert_matches_builtin(catalog) do
    builtin =
      CaseCatalog.sdk_catalog(catalog.catalog_id) ||
        flunk("the library has no catalog #{inspect(catalog.catalog_id)}")

    assert SemVer.to_canonical(catalog.protocol_version) ==
             SemVer.to_canonical(builtin.protocol_version),
           "protocolVersion mismatch"

    assert component_shapes(catalog) == component_shapes(builtin), "Component mismatch"
    assert function_signatures(catalog) == function_signatures(builtin), "Function mismatch"
  end

  defp component_shapes(catalog) do
    schema = Catalog.validation_schema(catalog)

    Map.new(schema["components"] || %{}, fn {name, component} ->
      {properties, required} = schema_shape(schema, component, [])

      {name,
       %{
         properties: properties |> MapSet.difference(MapSet.new(@envelope_fields)) |> Enum.sort(),
         required: required |> MapSet.difference(MapSet.new(@envelope_fields)) |> Enum.sort()
       }}
    end)
  end

  # The property and required names a schema declares, merging `allOf`
  # members and following local references (`seen` holds the references
  # being followed).
  defp schema_shape(document, %{} = schema, seen) do
    own =
      {MapSet.new(Map.keys(schema["properties"] || %{})), MapSet.new(schema["required"] || [])}

    referenced =
      case schema["$ref"] do
        "#" <> _ = ref ->
          if ref in seen,
            do: {MapSet.new(), MapSet.new()},
            else: schema_shape(document, resolve(document, ref), [ref | seen])

        _other ->
          {MapSet.new(), MapSet.new()}
      end

    members = Enum.map(schema["allOf"] || [], &schema_shape(document, &1, seen))
    Enum.reduce([referenced | members], own, &union_shape/2)
  end

  defp schema_shape(_document, _schema, _seen), do: {MapSet.new(), MapSet.new()}

  defp union_shape({properties, required}, {acc_properties, acc_required}),
    do: {MapSet.union(acc_properties, properties), MapSet.union(acc_required, required)}

  defp resolve(document, "#" <> pointer) do
    pointer
    |> String.split("/")
    |> Enum.drop(1)
    |> Enum.reduce(document, fn token, node ->
      token = token |> String.replace("~1", "/") |> String.replace("~0", "~")
      if is_map(node), do: node[token]
    end)
  end

  # Each catalog function's signature; system functions (`@index`), which
  # the library registers for evaluation, are left out.
  defp function_signatures(catalog) do
    for {name, function} <- catalog.functions, not String.starts_with?(name, "@"), into: %{} do
      {name,
       %{
         "returnType" => function.return_type || "any",
         "allowedCallers" => function.allowed_callers || "rendererOnly",
         "requiresUserActivation" => function.requires_user_activation == true
       }}
    end
  end

  defp list_only(names) when is_list(names), do: names
  defp list_only(_other), do: nil

  defp expected_names(nil, _lookup, _kind), do: :ok

  defp expected_names(names, lookup, kind) do
    for name <- if(is_map(names), do: Map.keys(names), else: names) do
      refute is_nil(lookup.(name)), "expected #{kind} #{inspect(name)} in the catalog"
    end

    :ok
  end

  defp check_payloads(catalog, expected) do
    for component <- expected["validComponents"] || [] do
      assert :ok == Payload.validate_component(catalog, component),
             "expected #{inspect(component)} to be valid"
    end

    for component <- expected["invalidComponents"] || [] do
      case Payload.validate_component(catalog, component) do
        {:error, %{category: :validation}} -> :ok
        other -> flunk("expected #{inspect(component)} to be invalid, got #{inspect(other)}")
      end
    end

    :ok
  end

  # Every `$ref` of the schema must be a `#` pointer that resolves inside
  # it, and there must be at least one.
  @doc false
  @spec assert_self_contained(map()) :: :ok
  def assert_self_contained(schema) do
    refs = collect_refs(schema)
    assert refs != [], "Catalog schema contains no references at all."

    for ref <- refs do
      assert String.starts_with?(ref, "#"), "Reference '#{ref}' leaves the catalog document."

      assert resolves?(schema, ref),
             "Reference '#{ref}' does not resolve within the catalog document."
    end

    :ok
  end

  defp collect_refs(%{} = node) do
    own = if is_binary(node["$ref"]), do: [node["$ref"]], else: []
    own ++ Enum.flat_map(node, fn {_key, value} -> collect_refs(value) end)
  end

  defp collect_refs(list) when is_list(list), do: Enum.flat_map(list, &collect_refs/1)
  defp collect_refs(_other), do: []

  defp resolves?(schema, "#" <> pointer) do
    tokens =
      pointer
      |> String.split("/")
      |> Enum.drop(1)
      |> Enum.map(&(&1 |> String.replace("~1", "/") |> String.replace("~0", "~")))

    walk(schema, tokens)
  end

  defp walk(_node, []), do: true

  defp walk(%{} = node, [token | rest]) do
    case node do
      %{^token => child} -> walk(child, rest)
      _missing -> false
    end
  end

  defp walk(_other, _tokens), do: false
end

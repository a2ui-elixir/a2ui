defmodule A2UIConformance.Handlers.CatalogSchema do
  @moduledoc false

  # `catalog_schema` (reference harness `validate_catalog_schema_case`,
  # L1116-1157): the schema a catalog document produces.
  #
  #   * `expectCatalog` — the schema must equal the published catalog
  #     consolidated with the common types it references (cross-document
  #     references made local, `$id`/`title`/`description`/
  #     `protocolVersion` dropped), compared strictly after sorting the
  #     `enum` / `required` sets. Published catalogs are loaded as
  #     authored.
  #   * `expect` — an inline expectation. The reference SDK compares the
  #     whole document; this harness follows the TypeScript harness and
  #     checks what the expectation names: `$schema`, `catalogId`,
  #     `instructions`, component type / property presence / `const` /
  #     `required` membership, function `returnType`, `$defs.theme`
  #     presence and the `anyComponent` / `anyFunction` unions.
  #
  # Union member order follows the document in the reference; maps are
  # unordered here, so unions are compared as sets of references.

  @behaviour A2UIConformance.Handler

  import ExUnit.Assertions

  alias A2UIConformance.{Case, CatalogFixtures, Matchers, Registry}
  alias A2UIConformance.Handlers.FromJson
  alias A2UICore.Catalog

  @impl true
  def run(%Case{raw: raw, protocol_version: version}, _context) do
    schema = FromJson.document(raw)

    catalog_id =
      CatalogFixtures.catalog_id(raw) || schema["catalogId"] || "https://a2ui.org/catalogs/basic"

    # Inline documents are flattened (the shape the expectations
    # describe); published catalogs keep their `allOf` envelopes.
    flatten? = not Map.has_key?(raw, "catalogPath") and not Map.has_key?(raw, "catalogFile")

    result =
      Catalog.from_json(schema,
        catalog_id: catalog_id,
        protocol_version: version,
        flatten: flatten?
      )

    case {result, raw["expectError"]} do
      {{:error, error}, expected} when not is_nil(expected) ->
        Matchers.assert_error(expected, error)
        :ok

      {{:error, error}, nil} ->
        flunk("catalog failed to load: #{Exception.message(error)}")

      {{:ok, catalog}, nil} ->
        compare(catalog, raw)
    end
  end

  defp compare(catalog, %{"expectCatalog" => spec}) do
    expected = consolidate(spec["catalogPath"], spec["commonTypesPath"])

    Matchers.assert_strict_equal(
      normalize(expected),
      normalize(Catalog.to_schema(catalog)),
      "catalog schema"
    )

    :ok
  end

  defp compare(catalog, %{"expect" => expected}) do
    matches(Catalog.to_schema(catalog), expected)
    :ok
  end

  defp compare(_catalog, _raw), do: :ok

  # -- published catalog consolidation -------------------------------------------

  defp consolidate(catalog_path, common_types_path) do
    catalog = load(catalog_path)
    common = load(common_types_path)["$defs"]

    catalog = Map.drop(catalog, ["$id", "title", "description", "protocolVersion"])
    defs = Map.get(catalog, "$defs", %{})
    defs = add_referenced(refs(catalog), defs, common)
    Map.put(catalog, "$defs", defs)
  end

  defp add_referenced([], defs, _common), do: defs

  defp add_referenced([name | rest], defs, common) do
    if not Map.has_key?(defs, name) and Map.has_key?(common, name) do
      add_referenced(refs(common[name]) ++ rest, Map.put(defs, name, common[name]), common)
    else
      add_referenced(rest, defs, common)
    end
  end

  defp load(path) do
    [Registry.reference_root(), path]
    |> Path.join()
    |> File.read!()
    |> Jason.decode!()
    |> Catalog.localize()
  end

  defp refs(%{} = node) do
    own =
      case node do
        %{"$ref" => "#/$defs/" <> name} -> [name]
        _other -> []
      end

    own ++ Enum.flat_map(node, fn {_key, value} -> refs(value) end)
  end

  defp refs(list) when is_list(list), do: Enum.flat_map(list, &refs/1)
  defp refs(_other), do: []

  # `enum` and `required` are sets; union member order is not significant
  # for maps that carry no order.
  defp normalize(%{} = node) do
    node
    |> Map.new(fn {key, value} -> {key, normalize(value)} end)
    |> sort_set("enum")
    |> sort_set("required")
    |> sort_union("oneOf")
  end

  defp normalize(list) when is_list(list), do: Enum.map(list, &normalize/1)
  defp normalize(other), do: other

  defp sort_set(node, key) do
    case node do
      %{^key => values} when is_list(values) ->
        Map.put(node, key, Enum.sort_by(values, &Jason.encode!/1))

      _other ->
        node
    end
  end

  defp sort_union(node, key) do
    case node do
      %{^key => values} when is_list(values) ->
        if Enum.all?(values, &match?(%{"$ref" => _}, &1)),
          do: Map.put(node, key, Enum.sort_by(values, & &1["$ref"])),
          else: node

      _other ->
        node
    end
  end

  # -- inline expectation ----------------------------------------------------------

  defp matches(actual, expected) do
    for key <- ["$schema", "catalogId", "instructions"], expected[key] do
      assert actual[key] == expected[key], "#{key} mismatch"
    end

    components(actual, expected["components"])
    functions(actual, expected["functions"])
    definitions(actual, expected["$defs"])
  end

  defp components(_actual, nil), do: :ok

  defp components(actual, expected) do
    present = actual["components"]
    assert is_map(present), "Missing components object in actual schema"

    for {name, wanted} <- expected do
      component = present[name]
      assert is_map(component), "Missing component '#{name}' in actual schema"
      component_type(component, wanted, name)
      component_properties(component, wanted["properties"], name)
      component_required(component, wanted["required"], name)
    end
  end

  defp component_type(component, wanted, name) do
    if type = wanted["type"],
      do: assert(component["type"] == type, "Component '#{name}' type mismatch")
  end

  defp component_properties(_component, nil, _name), do: :ok

  defp component_properties(component, wanted, name) do
    for {property, definition} <- wanted do
      actual = get_in(component, ["properties", property])
      assert is_map(actual), "Component '#{name}' missing property '#{property}'"

      property_type(actual, definition["type"])
      if const = definition["const"], do: assert(actual["const"] == const)
    end
  end

  # A property that is a `$ref` has its type in the target.
  defp property_type(_actual, nil), do: :ok

  defp property_type(actual, type) do
    if not is_map_key(actual, "$ref"), do: assert(actual["type"] == type)
  end

  defp component_required(_component, nil, _name), do: :ok

  defp component_required(component, wanted, name) do
    for field <- wanted do
      assert field in List.wrap(component["required"]),
             "Component '#{name}' missing required field '#{field}'"
    end
  end

  defp functions(_actual, nil), do: :ok

  defp functions(actual, expected) do
    present = actual["functions"]
    assert is_map(present), "Missing functions object in actual schema"

    for {name, wanted} <- expected do
      function = present[name]
      assert is_map(function), "Missing function '#{name}' in actual schema"
      if type = wanted["returnType"], do: assert(function["returnType"] == type)
    end
  end

  defp definitions(_actual, nil), do: :ok

  defp definitions(actual, expected) do
    defs = actual["$defs"]
    assert is_map(defs), "Missing $defs in actual schema"

    if expected["theme"], do: assert(is_map(defs["theme"]), "Missing $defs.theme")

    for key <- ["anyComponent", "anyFunction"], wanted = expected[key] do
      assert normalize(defs[key]) == normalize(wanted), "$defs.#{key} mismatch"
    end
  end
end

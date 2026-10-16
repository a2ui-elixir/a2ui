defmodule A2UIConformance.Handlers.CatalogDocument do
  @moduledoc false

  # The catalog document actions (reference harness
  # `validate_validation_schema_case`, `validate_round_trip_case`,
  # `validate_to_json_case`):
  #
  #   * `validation_schema` — the catalog's validation schema equals the
  #     golden file `expectFile` names, or loading fails with
  #     `expectError`;
  #   * `round_trip` — `from_json(document) |> to_json()` equals the
  #     document, and a second round trip changes nothing;
  #   * `to_json` — the document of the case's catalog, or of the
  #     library's own implementation (`builtinCatalog`), equals
  #     `expectFile`.
  #
  # Comparisons ignore key order and the order of `enum` values and
  # `required` names.

  @behaviour A2UIConformance.Handler

  import ExUnit.Assertions

  alias A2UIConformance.{Case, CaseCatalog, CatalogFixtures, Matchers}
  alias A2UICore.Catalog

  @impl true
  def run(%Case{action: "validation_schema", raw: raw, protocol_version: version}, _context) do
    refute Map.has_key?(raw, "expect"), "validation_schema cases take no expect"
    document = CaseCatalog.document(raw)

    catalog_id =
      CatalogFixtures.catalog_id(raw) || CaseCatalog.plain(document)["catalogId"] ||
        "https://a2ui.org/catalogs/basic"

    result = Catalog.from_json(document, catalog_id: catalog_id, protocol_version: version)

    case {result, raw["expectError"]} do
      {{:error, error}, expected} when not is_nil(expected) ->
        Matchers.assert_error(expected, error)

      {{:ok, _catalog}, expected} when not is_nil(expected) ->
        flunk("expected #{inspect(expected)}, but the catalog loaded")

      {{:error, error}, nil} ->
        flunk("catalog failed to load: #{Exception.message(error)}")

      {{:ok, catalog}, nil} ->
        catalog = CaseCatalog.with_peers(catalog, raw)
        assert raw["expectFile"], "validation_schema cases require expectFile or expectError"
        assert_same(Catalog.validation_schema(catalog), raw["expectFile"], "validation_schema")
    end

    :ok
  end

  def run(%Case{action: "round_trip", raw: raw, protocol_version: version}, _context) do
    unexpected = Enum.filter(["expect", "expectFile"], &Map.has_key?(raw, &1))
    assert unexpected == [], "round_trip cases take no #{inspect(unexpected)}"

    document = CaseCatalog.document(raw)
    options = [catalog_id: CatalogFixtures.catalog_id(raw), protocol_version: version]

    out = document |> Catalog.from_json!(options) |> Catalog.to_json()

    assert CaseCatalog.normalize_sets(out) ==
             CaseCatalog.normalize_sets(CaseCatalog.plain(document)),
           "to_json does not give the document back"

    again = out |> Catalog.from_json!(options) |> Catalog.to_json()

    assert CaseCatalog.normalize_sets(again) == CaseCatalog.normalize_sets(out),
           "a second round trip changes the document"

    :ok
  end

  def run(%Case{action: "to_json", raw: raw, protocol_version: version}, _context) do
    refute Map.has_key?(raw, "expect"), "to_json cases take expectFile, not expect"

    catalog =
      case raw["builtinCatalog"] do
        nil ->
          raw
          |> CaseCatalog.document()
          |> Catalog.from_json!(
            catalog_id: CatalogFixtures.catalog_id(raw),
            protocol_version: version
          )

        name ->
          CaseCatalog.builtin(name, version) ||
            flunk("no built-in #{name} catalog for #{version}")
      end

    assert_same(Catalog.to_json(catalog), raw["expectFile"], "to_json")
    :ok
  end

  defp assert_same(actual, expect_file, what) do
    expected = expect_file |> CaseCatalog.read() |> CaseCatalog.plain()

    assert CaseCatalog.normalize_sets(actual) == CaseCatalog.normalize_sets(expected),
           "#{what} differs from #{expect_file}"
  end
end

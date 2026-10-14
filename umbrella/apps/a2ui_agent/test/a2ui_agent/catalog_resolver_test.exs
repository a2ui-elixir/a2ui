defmodule A2UIAgent.CatalogResolverTest do
  @moduledoc false
  use ExUnit.Case, async: true

  alias A2UIAgent.{CatalogConfig, CatalogResolver, CatalogTransformer}
  alias A2UICore.{Catalog, Error}

  defp config(id, version \\ "v1.0", transformers \\ []) do
    catalog =
      Catalog.from_json!(%{
        "catalogId" => id,
        "protocolVersion" => version,
        "components" => %{
          "Text" => %{"type" => "object", "properties" => %{"text" => %{"type" => "string"}}},
          "Icon" => %{"type" => "object", "properties" => %{"name" => %{"type" => "string"}}}
        }
      })

    CatalogConfig.new(catalog, transformers: transformers)
  end

  defp inline(id) do
    %{
      "catalogId" => id,
      "components" => %{"Marquee" => %{"type" => "object", "properties" => %{}}}
    }
  end

  defp ids({:ok, catalogs}), do: Enum.map(catalogs, & &1.catalog_id)

  defp error!(result, category) do
    assert {:error, %Error{category: ^category, message: message}} = result
    message
  end

  test "activates the named catalogs in the renderer's order" do
    configs = [config("a"), config("b"), config("c")]
    capabilities = %{"v1.0" => %{"supportedCatalogIds" => ["c", "x", "a", "c"]}}

    assert ids(CatalogResolver.resolve(configs, capabilities)) == ["c", "a"]
  end

  test "without capabilities every registered catalog is active, transformed" do
    configs = [config("b", "v1.0", [CatalogTransformer.component_pruning(["Text"])]), config("a")]

    assert {:ok, [b, a]} = CatalogResolver.resolve(configs, nil)
    assert Map.keys(b.components) == ["Text"]
    assert a.catalog_id == "a"
    assert CatalogResolver.resolve([], nil) == {:ok, []}
  end

  test "a duplicate registration resolves to the first one" do
    first = config("a", "v1.0", [CatalogTransformer.component_pruning(["Icon"])])
    capabilities = %{"v1.0" => %{"supportedCatalogIds" => ["a"]}}

    assert {:ok, [catalog]} = CatalogResolver.resolve([first, config("a")], capabilities)
    assert Map.keys(catalog.components) == ["Icon"]
  end

  test "inline catalogs join when accepted, after the registered ones, once per id" do
    capabilities = %{
      "v1.0" => %{
        "supportedCatalogIds" => ["a"],
        "inlineCatalogs" => [inline("a"), inline("r/one"), inline("r/two"), inline("r/one")]
      }
    }

    assert ids(
             CatalogResolver.resolve([config("a")], capabilities, accepts_inline_catalogs: true)
           ) ==
             ["a", "r/one", "r/two"]

    assert ids(CatalogResolver.resolve([config("a")], capabilities)) == ["a"]
  end

  test "inline catalogs take the registered catalogs' protocol version" do
    capabilities = %{
      "v0.9" => %{"supportedCatalogIds" => [], "inlineCatalogs" => [inline("r/inline")]}
    }

    assert {:ok, [catalog]} =
             CatalogResolver.resolve([config("a", "v0.9.1")], capabilities,
               accepts_inline_catalogs: true
             )

    assert catalog.protocol_version == "v0.9.1"
  end

  test "malformed inline catalogs are catalog errors even when not accepted" do
    entry = fn inline ->
      %{"v1.0" => %{"supportedCatalogIds" => ["a"], "inlineCatalogs" => inline}}
    end

    assert error!(CatalogResolver.resolve([config("a")], entry.("x")), :catalog) =~ "not a list"

    assert error!(CatalogResolver.resolve([config("a")], entry.(["x"])), :catalog) =~
             "entry 0 is not an object"

    assert error!(CatalogResolver.resolve([config("a")], entry.([%{}])), :catalog) =~
             "entry 0 has no string 'catalogId'"

    assert error!(CatalogResolver.resolve([config("a")], entry.([inline("")])), :catalog) =~
             "catalog_id must be provided"
  end

  test "no catalog in common, or none registered, is a catalog error" do
    capabilities = %{"v1.0" => %{"supportedCatalogIds" => ["x"]}}

    assert error!(CatalogResolver.resolve([config("a")], capabilities), :catalog) =~
             ~s(Agent-supported catalogs are: ["a"])

    assert error!(CatalogResolver.resolve([], capabilities), :catalog) =~
             "No catalogs are registered"
  end

  test "registered catalogs that read different entries are a catalog error" do
    capabilities = %{"v1.0" => %{"supportedCatalogIds" => ["a"]}}

    assert error!(
             CatalogResolver.resolve([config("a"), config("b", "v0.9")], capabilities),
             :catalog
           ) =~
             "'a' reads 'v1.0' and 'b' reads 'v0.9'"

    v09 = %{"v0.9" => %{"supportedCatalogIds" => ["b", "c"]}}

    assert ids(CatalogResolver.resolve([config("b", "v0.9"), config("c", "v0.9.1")], v09)) == [
             "b",
             "c"
           ]
  end

  test "malformed capabilities are validation errors" do
    configs = [config("a")]

    assert error!(CatalogResolver.resolve(configs, ["v1.0"]), :validation) =~ "must be a mapping"

    assert error!(CatalogResolver.resolve(configs, %{"v0.8" => %{}}), :validation) =~
             "no 'v1.0' entry"

    assert error!(CatalogResolver.resolve(configs, %{"v1.0" => "a"}), :validation) =~
             "not an object"

    assert error!(
             CatalogResolver.resolve(configs, %{"v1.0" => %{"supportedCatalogIds" => "a"}}),
             :validation
           ) =~ "must be a list of strings"

    assert error!(
             CatalogResolver.resolve(configs, %{
               "v1.0" => %{"supportedCatalogIds" => ["a"], "extra" => 1}
             }),
             :validation
           ) =~ "extra inputs are not permitted (extra)"
  end
end

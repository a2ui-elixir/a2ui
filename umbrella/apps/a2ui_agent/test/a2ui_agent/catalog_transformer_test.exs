defmodule A2UIAgent.CatalogTransformerTest do
  @moduledoc false
  use ExUnit.Case, async: true

  doctest A2UIAgent.CatalogTransformer

  alias A2UIAgent.{CatalogConfig, CatalogTransformer}
  alias A2UICore.Catalog

  @document %{
    "catalogId" => "acme/shapes",
    "protocolVersion" => "v1.0",
    "instructions" => "Prefer cards.",
    "components" => %{
      "Card" => %{
        "type" => "object",
        "properties" => %{"child" => %{"$ref" => "#/$defs/ComponentId"}},
        "required" => ["child"]
      },
      "Swatch" => %{
        "type" => "object",
        "properties" => %{"color" => %{"$ref" => "#/$defs/Color"}}
      }
    },
    "functions" => %{
      "lighten" => %{
        "type" => "object",
        "properties" => %{"args" => %{"$ref" => "#/$defs/ColorArgs"}}
      },
      "required" => %{"type" => "object"}
    },
    "$defs" => %{
      "Color" => %{"type" => "string", "pattern" => "^#"},
      "ColorArgs" => %{
        "type" => "object",
        "properties" => %{"color" => %{"$ref" => "#/$defs/Color"}}
      },
      "Unused" => %{"type" => "null"},
      "anyComponent" => %{
        "oneOf" => [%{"$ref" => "#/components/Card"}, %{"$ref" => "#/components/Swatch"}]
      }
    }
  }

  setup do
    {:ok, catalog: Catalog.from_json!(@document)}
  end

  test "component pruning keeps the named components and their definitions", %{catalog: c} do
    pruned = CatalogTransformer.apply_all(c, [CatalogTransformer.component_pruning(["Card"])])

    assert Map.keys(pruned.components) == ["Card"]
    assert Map.keys(pruned.functions) == ["lighten", "required"]
    assert pruned.instructions == "Prefer cards."

    schema = Catalog.to_schema(pruned)
    assert schema["$defs"]["anyComponent"]["oneOf"] == [%{"$ref" => "#/components/Card"}]
    # The kept function still references Color through its arguments.
    assert Map.has_key?(schema["$defs"], "Color")
    refute Map.has_key?(schema["$defs"], "Unused")
  end

  test "pruning both kinds drops the definitions nothing reaches", %{catalog: c} do
    pruned =
      CatalogTransformer.apply_all(c, [
        CatalogTransformer.component_pruning(["Card"]),
        CatalogTransformer.function_pruning(["required"])
      ])

    defs = Catalog.to_schema(pruned)["$defs"]
    refute Map.has_key?(defs, "Color")
    refute Map.has_key?(defs, "ColorArgs")
    assert defs["anyFunction"]["oneOf"] == [%{"$ref" => "#/functions/required"}]
  end

  test "nil or an empty list keeps nothing; repeated names count once", %{catalog: c} do
    assert CatalogTransformer.apply_all(c, [CatalogTransformer.function_pruning(nil)]).functions ==
             %{}

    assert CatalogTransformer.apply_all(c, [CatalogTransformer.component_pruning([])]).components ==
             %{}

    twice =
      CatalogTransformer.apply_all(c, [CatalogTransformer.component_pruning(["Card", "Card"])])

    assert Map.keys(twice.components) == ["Card"]
  end

  test "a single string is rejected" do
    assert_raise ArgumentError, ~r/not a string/, fn ->
      CatalogTransformer.component_pruning("Card")
    end

    assert_raise ArgumentError, ~r/not a string/, fn ->
      CatalogTransformer.function_pruning("required")
    end
  end

  test "functions are transformers too, and nil applies none", %{catalog: c} do
    rename = fn catalog -> Catalog.derive(catalog, "acme/renamed") end
    assert CatalogTransformer.apply_all(c, [rename]).catalog_id == "acme/renamed"
    assert CatalogTransformer.apply_all(c, nil) == c
  end

  describe "CatalogConfig" do
    @describetag :tmp_dir

    test "new/2 computes the transformed catalog once", %{catalog: c} do
      config =
        CatalogConfig.new(c, transformers: [CatalogTransformer.component_pruning(["Swatch"])])

      assert config.catalog == c
      assert Map.keys(config.transformed.components) == ["Swatch"]
      assert CatalogConfig.new(c).transformed == c
    end

    test "from_path/2 loads and registers a file", %{tmp_dir: dir} do
      path = Path.join(dir, "shapes.json")
      File.write!(path, Jason.encode!(Map.delete(@document, "catalogId")))

      assert {:ok, config} =
               CatalogConfig.from_path(path,
                 catalog_id: "acme/from-path",
                 transformers: [CatalogTransformer.function_pruning([])]
               )

      assert config.transformed.catalog_id == "acme/from-path"
      assert config.transformed.functions == %{}

      assert {:error, %A2UICore.Error{category: :catalog}} = CatalogConfig.from_path(path)
    end
  end
end

defmodule A2UICore.Catalog.BasicTest do
  @moduledoc false
  use ExUnit.Case, async: true

  alias A2UICore.Catalog
  alias A2UICore.Catalog.Basic

  defmodule CustomFormatter do
    @moduledoc false
    @behaviour A2UICore.Formatter
    @impl true
    def decimal(_value, _opts), do: "custom"
    @impl true
    def currency(_value, _currency, _opts), do: "custom"
    @impl true
    def date(_value, _format, _opts), do: "custom"
    @impl true
    def plural(_value, _opts), do: "other"
  end

  @basic_components ~w(Text Image Icon Video AudioPlayer Row Column List Card Tabs Modal Button
                       CheckBox TextField DateTimeInput ChoicePicker Slider Divider)

  describe "catalog/2" do
    test "v0.9 declares the basic components and evaluates its functions" do
      catalog = Basic.catalog("v0.9")

      assert catalog.protocol_version == "v0.9"
      refute Catalog.v1?(catalog)

      for name <- @basic_components do
        assert Map.has_key?(catalog.components, name), "missing component #{name}"
      end

      assert catalog.functions["formatString"].execute != nil
      refute Map.has_key?(catalog.functions, "@index")
    end

    test "v0.9.1 reuses the v0.9 behaviour" do
      catalog = Basic.catalog("v0.9.1")
      assert catalog.functions["required"].execute != nil
      assert catalog.catalog_id =~ "v0_9"
    end

    test "v1.0 adds the system functions" do
      catalog = Basic.catalog("v1.0")

      assert Catalog.v1?(catalog)
      assert catalog.functions["@index"].execute != nil
      assert catalog.functions["required"].execute != nil
      assert catalog.catalog_id =~ "v1_0"
    end

    test "the schema is self-contained" do
      for version <- ["v0.9", "v1.0"] do
        schema = version |> Basic.catalog() |> Catalog.to_schema()
        refs = collect_refs(schema)

        for ref <- refs, String.starts_with?(ref, "#/$defs/") do
          name = ref |> String.replace_prefix("#/$defs/", "") |> String.split("/") |> hd()
          assert Map.has_key?(schema["$defs"], name), "#{version}: unresolved #{ref}"
        end

        refute Enum.any?(refs, &String.contains?(&1, "common_types.json"))
      end
    end

    test "the declared catalog has schemas but no implementations" do
      for version <- ["v0.9", "v1.0"] do
        declared = Basic.declared(version)

        assert declared == Basic.declared(version)
        assert Map.has_key?(declared.functions, "formatString")
        assert Enum.all?(declared.functions, fn {_name, function} -> function.execute == nil end)
      end
    end

    test "implement/3 attaches implementations to a derived catalog" do
      derived = "v1.0" |> Basic.declared() |> Catalog.derive("urn:derived:basic")
      implemented = Basic.implement(derived, "v1.0")

      assert implemented.catalog_id == "urn:derived:basic"
      assert implemented.functions["required"].execute != nil
      assert implemented.functions["@index"].execute != nil
    end

    test "cached data holds no closures" do
      Basic.catalog("v1.0")
      key = {Basic, "v1.0"}

      refute contains_function?(:persistent_term.get(key))
    end

    test "a custom formatter builds an uncached catalog" do
      catalog = Basic.catalog("v0.9", formatter: CustomFormatter)
      function = catalog.functions["formatNumber"]

      assert {:ok, "custom"} = function.execute.(%{"value" => 1}, nil)

      assert {:ok, "1"} =
               Basic.catalog("v0.9").functions["formatNumber"].execute.(%{"value" => 1}, nil)
    end
  end

  defp contains_function?(term) when is_function(term), do: true
  defp contains_function?(%_{} = struct), do: struct |> Map.from_struct() |> contains_function?()

  defp contains_function?(%{} = map),
    do:
      Enum.any?(map, fn {key, value} -> contains_function?(key) or contains_function?(value) end)

  defp contains_function?(list) when is_list(list), do: Enum.any?(list, &contains_function?/1)
  defp contains_function?(_other), do: false

  defp collect_refs(%{} = node) do
    own = if is_binary(node["$ref"]), do: [node["$ref"]], else: []
    own ++ Enum.flat_map(Map.values(node), &collect_refs/1)
  end

  defp collect_refs(list) when is_list(list), do: Enum.flat_map(list, &collect_refs/1)
  defp collect_refs(_other), do: []
end

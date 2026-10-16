defmodule A2UICore.Catalog.DocumentTest do
  @moduledoc false
  use ExUnit.Case, async: true

  alias A2UICore.{Catalog, Error}
  alias A2UICore.Catalog.{Component, Document, Function}

  defp ordered(json), do: Jason.decode!(json, objects: :ordered_objects)

  defp error_message(result) do
    assert {:error, %Error{category: :catalog, message: message}} = result
    message
  end

  describe "reading" do
    test "list-form functions keep their names unique" do
      document = %{
        "catalogId" => "x",
        "functions" => [%{"name" => "f", "type" => "object"}, %{"name" => "f"}]
      }

      assert error_message(Catalog.from_json(document, protocol_version: "v1.0")) ==
               "Catalog 'x' function definition 1 duplicates the name 'f'."
    end

    test "argument names are checked in every form an entry declares them" do
      check = fn spec ->
        Catalog.from_json(%{"catalogId" => "x", "functions" => %{"f" => spec}},
          protocol_version: "v1.0"
        )
      end

      assert error_message(check.(%{"args" => %{"properties" => %{"a b" => %{}}}})) =~ "'a b'"

      assert error_message(check.(%{"parameters" => %{"a-b" => %{"type" => "string"}}})) =~
               "'a-b'"

      all_of = %{
        "allOf" => [%{"properties" => %{"ok" => %{}}}, %{"properties" => %{"x y" => %{}}}]
      }

      assert error_message(check.(%{"args" => all_of})) =~ "'x y'"

      assert {:ok, _catalog} = check.(%{"args" => %{"type" => "string"}})
      assert {:ok, _catalog} = check.(%{"properties" => %{"call" => %{}}})
      assert {:ok, _catalog} = check.(%{"args" => %{"$ref" => "#/$defs/Args"}})
      assert {:ok, _catalog} = check.(%{"type" => "object"})
    end

    test "component schemas must be objects" do
      for {value, name} <- [{[1], "list"}, {1.5, "float"}, {true, "bool"}, {nil, "NoneType"}] do
        document = %{"catalogId" => "x", "components" => %{"Text" => value}}

        assert error_message(Catalog.from_json(document, protocol_version: "v1.0")) ==
                 "Component 'Text' schema must be a JSON schema object, got #{name}."
      end
    end

    test "to_plain/1 turns ordered objects into maps" do
      assert Document.to_plain([ordered(~s({"b": {"c": 1}, "a": [2]}))]) ==
               [%{"a" => [2], "b" => %{"c" => 1}}]
    end
  end

  describe "themes" do
    test "styles that are not a schema are the theme's properties" do
      catalog =
        ~s({"catalogId": "x", "styles": {"primary": {"type": "string"}, "font": {"type": "string"}}})
        |> ordered()
        |> Catalog.from_json!(protocol_version: "v0.9")

      assert catalog.theme_location == "styles"
      assert catalog.theme["type"] == "object"

      assert catalog |> Catalog.to_json(ordered: true) |> Jason.encode!() ==
               ~s({"catalogId":"x","styles":{"primary":{"type":"string"},"font":{"type":"string"}}})
    end

    test "styles written as a schema are kept as an unknown key" do
      document = %{"catalogId" => "x", "styles" => %{"type" => "object"}}
      catalog = Catalog.from_json!(document, protocol_version: "v0.9")

      assert catalog.theme_location == nil
      assert Catalog.to_json(catalog) == document
    end

    test "a theme in $defs goes back to $defs, after the other definitions" do
      catalog =
        ~s({"catalogId": "x", "$defs": {"theme": {"type": "object"}, "Own": {"type": "string"}}})
        |> ordered()
        |> Catalog.from_json!(protocol_version: "v0.9")

      assert catalog.theme_location == "$defs"

      assert catalog |> Catalog.to_json(ordered: true) |> Jason.encode!() ==
               ~s({"catalogId":"x","$defs":{"Own":{"type":"string"},"theme":{"type":"object"}}})
    end

    test "a theme defined in code points its common types at the common types document" do
      theme = %{
        "type" => "object",
        "properties" => %{"accent" => %{"$ref" => "#/$defs/DynamicString"}}
      }

      catalog = Catalog.new!("x", "v0.9", theme: theme)

      assert Catalog.to_json(catalog)["$defs"]["theme"]["properties"]["accent"] ==
               %{"$ref" => "common_types.json#/$defs/DynamicString"}
    end
  end

  describe "writing functions" do
    test "list-form functions are written with their name first" do
      catalog =
        ~s({"catalogId": "x", "functions": [{"returnType": "string", "name": "f", "type": "object"}]})
        |> ordered()
        |> Catalog.from_json!(protocol_version: "v0.9")

      assert catalog |> Catalog.to_json(ordered: true) |> Jason.encode!() ==
               ~s({"catalogId":"x","functions":[{"name":"f","returnType":"string","type":"object"}]})
    end

    test "a function defined by its arguments is written in the call shape of its version" do
      args = %{"properties" => %{"value" => %{"$ref" => "#/$defs/DynamicString"}}}

      function = %{
        Function.from_schema("tint", args)
        | description: "Tints.",
          return_type: "string",
          allowed_callers: "agentOnly",
          requires_user_activation: true
      }

      refute Function.definition?(function)

      v1 = Catalog.new!("x", "v1.0", functions: [function])

      assert v1 |> Catalog.to_json(ordered: true) |> Jason.encode!() =~
               ~s("tint":{"type":"object","properties":{"@call":{"const":"tint"},) <>
                 ~s("args":{"properties":{"value":{"$ref":"common_types.json#/$defs/DynamicString"}},) <>
                 ~s("type":"object"}},"required":["@call","args"],"description":"Tints.",) <>
                 ~s("returnType":"string","allowedCallers":"agentOnly","requiresUserActivation":true})

      v09 = Catalog.new!("x", "v0.9", functions: [%{function | description: nil}])

      assert Catalog.to_json(v09)["functions"]["tint"] == %{
               "type" => "object",
               "properties" => %{
                 "call" => %{"const" => "tint"},
                 "args" => %{
                   "type" => "object",
                   "properties" => %{
                     "value" => %{"$ref" => "common_types.json#/$defs/DynamicString"}
                   }
                 },
                 "returnType" => %{"const" => "string"}
               },
               "required" => ["call", "args"],
               "unevaluatedProperties" => false
             }
    end

    test "metadata that differs from the entry is written into it" do
      v09_entry = %{
        "type" => "object",
        "properties" => %{"call" => %{"const" => "f"}, "returnType" => %{"const" => "string"}}
      }

      v1_entry = %{"type" => "object", "properties" => %{"@call" => %{"const" => "g"}}}

      catalog =
        Catalog.new!("x", "v1.0",
          functions: [
            %{Function.from_schema("f", v09_entry) | return_type: "number"},
            %{
              Function.from_schema("g", v1_entry)
              | return_type: "boolean",
                allowed_callers: "rendererOrAgent",
                requires_user_activation: true
            }
          ]
        )

      functions = Catalog.to_json(catalog)["functions"]

      assert functions["f"]["properties"]["returnType"] == %{"const" => "number"}
      refute Map.has_key?(functions["f"], "returnType")

      assert %{
               "returnType" => "boolean",
               "allowedCallers" => "rendererOrAgent",
               "requiresUserActivation" => true
             } = functions["g"]
    end
  end

  test "composition constraints are written beside the component schema" do
    component = %{
      Component.from_schema("Tab", %{"type" => "object", "allowedParents" => ["Old"]})
      | allowed_parents: ["Tabs"],
        allowed_children: nil
    }

    with_null = Component.from_schema("Row", %{"type" => "object", "allowedChildren" => nil})
    catalog = Catalog.new!("x", "v1.0", components: [component, with_null])
    components = Catalog.to_json(catalog)["components"]

    assert components["Tab"] == %{"type" => "object", "allowedParents" => ["Tabs"]}
    assert components["Row"] == %{"type" => "object", "allowedChildren" => nil}
  end

  test "a catalog id given only as an option is not written" do
    catalog =
      Catalog.from_json!(%{"components" => %{}}, catalog_id: "x", protocol_version: "v1.0")

    refute catalog.declares_catalog_id
    assert Catalog.to_json(catalog) == %{"components" => %{}}
  end
end

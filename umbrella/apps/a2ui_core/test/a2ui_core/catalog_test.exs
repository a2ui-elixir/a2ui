defmodule A2UICore.CatalogTest do
  @moduledoc false
  use ExUnit.Case, async: true

  alias A2UICore.Catalog
  alias A2UICore.Catalog.Component
  alias A2UICore.Catalog.Function
  alias A2UICore.Error
  alias A2UICore.Functions.System

  @card %{
    "type" => "object",
    "allOf" => [
      %{"$ref" => "common_types.json#/$defs/ComponentCommon"},
      %{"$ref" => "#/$defs/CatalogComponentCommon"},
      %{
        "type" => "object",
        "properties" => %{
          "component" => %{"const" => "Card"},
          "title" => %{"$ref" => "common_types.json#/$defs/DynamicString"},
          "child" => %{"$ref" => "common_types.json#/$defs/ComponentId"}
        },
        "required" => ["component", "title"]
      }
    ],
    "unevaluatedProperties" => false
  }

  @double %{
    "type" => "object",
    "properties" => %{
      "@call" => %{"const" => "double"},
      "args" => %{"type" => "object", "properties" => %{"value" => %{"type" => "number"}}}
    },
    "required" => ["@call", "args"],
    "returnType" => "number",
    "allowedCallers" => "rendererOnly",
    "requiresUserActivation" => true
  }

  defp v1_document(extra \\ %{}) do
    Map.merge(
      %{
        "catalogId" => "urn:test:v1",
        "components" => %{"Card" => @card},
        "functions" => %{"double" => @double},
        "$defs" => %{
          "CatalogComponentCommon" => %{
            "type" => "object",
            "properties" => %{"weight" => %{"type" => "number"}}
          }
        }
      },
      extra
    )
  end

  defp error_message(result) do
    assert {:error, %Error{category: :catalog, message: message}} = result
    message
  end

  describe "from_json/2" do
    test "builds components, functions and the self-contained schema" do
      assert {:ok, catalog} = Catalog.from_json(v1_document(), protocol_version: "v1.0")

      assert catalog.catalog_id == "urn:test:v1"
      assert catalog.protocol_version == "v1.0"
      assert %Component{name: "Card"} = catalog.components["Card"]
      assert %Function{name: "double", return_type: "number"} = catalog.functions["double"]
      assert catalog.functions["double"].allowed_callers == "rendererOnly"
      assert catalog.functions["double"].requires_user_activation == true
      assert catalog.functions["double"].execute == nil
      assert Catalog.v1?(catalog)
    end

    test "the validation schema's references are local; the document keeps them as written" do
      catalog = Catalog.from_json!(v1_document(), protocol_version: "v1.0")
      schema = Catalog.validation_schema(catalog)

      assert schema |> refs() |> Enum.all?(&String.starts_with?(&1, "#/"))
      assert schema["$schema"] == "https://json-schema.org/draft/2020-12/schema"
      assert schema["catalogId"] == "urn:test:v1"
      assert Catalog.to_schema(catalog) == schema

      assert Catalog.to_json(catalog)["components"]["Card"] == @card
    end

    test "referenced common types are bundled, unreferenced ones are not" do
      defs =
        v1_document()
        |> Catalog.from_json!(protocol_version: "v1.0")
        |> Catalog.validation_schema()
        |> Map.fetch!("$defs")

      for name <- ~w(ComponentId DynamicString DataBinding FunctionCall AccessibilityAttributes) do
        assert Map.has_key?(defs, name), "expected #{name} to be bundled"
      end

      refute Map.has_key?(defs, "Action")
      refute Map.has_key?(defs, "ChildList")
    end

    test "anyComponent and anyFunction are generated, sorted" do
      document =
        v1_document(%{
          "components" => %{"Zed" => @card, "Alpha" => @card},
          "functions" => %{"zeta" => @double, "alpha" => @double}
        })

      schema = document |> Catalog.from_json!(protocol_version: "v1.0") |> Catalog.to_schema()

      assert schema["$defs"]["anyComponent"] == %{
               "discriminator" => %{"propertyName" => "component"},
               "oneOf" => [%{"$ref" => "#/components/Alpha"}, %{"$ref" => "#/components/Zed"}]
             }

      assert schema["$defs"]["anyFunction"] == %{
               "oneOf" => [%{"$ref" => "#/functions/alpha"}, %{"$ref" => "#/functions/zeta"}]
             }
    end

    test "an authored anyComponent restricts the components" do
      document =
        v1_document(%{
          "components" => %{"Card" => @card, "Hidden" => @card},
          "$defs" => %{
            "CatalogComponentCommon" => %{"type" => "object"},
            "anyComponent" => %{"oneOf" => [%{"$ref" => "#/components/Card"}]}
          }
        })

      catalog = Catalog.from_json!(document, protocol_version: "v1.0")

      assert Map.keys(catalog.components) == ["Card"]

      assert Catalog.to_schema(catalog)["$defs"]["anyComponent"]["oneOf"] ==
               [%{"$ref" => "#/components/Card"}]
    end

    test "an authored anyFunction restricts the functions" do
      document =
        v1_document(%{
          "functions" => %{"double" => @double, "triple" => @double},
          "$defs" => %{
            "CatalogComponentCommon" => %{"type" => "object"},
            "anyFunction" => %{"oneOf" => [%{"$ref" => "#/functions/triple"}]}
          }
        })

      catalog = Catalog.from_json!(document, protocol_version: "v1.0")
      assert Map.keys(catalog.functions) == ["triple"]
    end

    test "a referenced but undefined anyFunction is synthesized as unsatisfiable" do
      document = %{
        "catalogId" => "urn:test:no-functions",
        "components" => %{
          "Button" => %{
            "type" => "object",
            "properties" => %{
              "component" => %{"const" => "Button"},
              "onTap" => %{"$ref" => "common_types.json#/$defs/FunctionCall"}
            },
            "required" => ["component"]
          }
        }
      }

      schema = document |> Catalog.from_json!(protocol_version: "v1.0") |> Catalog.to_schema()
      assert schema["$defs"]["anyFunction"] == %{"not" => %{}}
    end

    test "system functions are added in code and stay out of the documents" do
      catalog =
        v1_document()
        |> Catalog.from_json!(protocol_version: "v1.0")
        |> Catalog.put_system_functions(System.functions("v1.0"))

      assert Map.has_key?(catalog.functions, "@index")
      assert Map.keys(catalog.schema["functions"]) == ["double"]
      assert Map.keys(Catalog.to_json(catalog)["functions"]) == ["double"]
    end

    test "theme comes from the top level or from $defs" do
      theme = %{"type" => "object", "properties" => %{"accent" => %{"type" => "string"}}}

      top = Catalog.from_json!(v1_document(%{"theme" => theme}), protocol_version: "v1.0")
      assert top.theme == theme
      assert top.schema["$defs"]["theme"]["properties"] == theme["properties"]
      assert Catalog.to_json(top)["theme"] == theme

      nested =
        Catalog.from_json!(
          v1_document(%{"$defs" => %{"theme" => theme, "CatalogComponentCommon" => %{}}}),
          protocol_version: "v1.0"
        )

      assert nested.theme == theme
      assert Catalog.to_json(nested)["$defs"]["theme"] == theme
    end

    test "instructions are kept" do
      catalog =
        Catalog.from_json!(v1_document(%{"instructions" => "Be nice."}), protocol_version: "v1.0")

      assert catalog.instructions == "Be nice."
      assert catalog.schema["instructions"] == "Be nice."
    end

    test "catalog_id and protocol_version options override the document" do
      document = v1_document(%{"protocolVersion" => "v0.9"})

      catalog = Catalog.from_json!(document, catalog_id: "urn:other", protocol_version: "v1.0")
      assert catalog.catalog_id == "urn:other"
      assert catalog.protocol_version == "v1.0"

      from_document = Catalog.from_json!(document)
      assert from_document.protocol_version == "v0.9"
    end

    test "functions may be a list of named definitions" do
      document =
        v1_document(%{"functions" => [Map.put(@double, "name", "double")]})

      catalog = Catalog.from_json!(document, protocol_version: "v1.0")
      assert Map.keys(catalog.functions) == ["double"]
      refute Map.has_key?(catalog.functions["double"].schema, "name")
    end
  end

  describe "from_json/2 errors" do
    test "missing catalog id" do
      assert error_message(Catalog.from_json(%{"components" => %{}}, protocol_version: "v1.0")) ==
               "catalog_id must be provided or exist in catalog schema."
    end

    test "the protocol version defaults to the document's, else 0.9" do
      assert Catalog.from_json!(%{"catalogId" => "x"}).protocol_version == "0.9"

      assert Catalog.from_json!(%{"catalogId" => "x", "protocolVersion" => "1.0"}).protocol_version ==
               "1.0"
    end

    test "from v1.0 a document may not declare a function in the @ namespace" do
      document = v1_document(%{"functions" => %{"@index" => @double}})

      assert error_message(Catalog.from_json(document, protocol_version: "v1.0")) ==
               "Invalid UAX #31 function identifier: '@index'"
    end

    test "unsupported protocol version" do
      assert error_message(Catalog.from_json(%{"catalogId" => "x"}, protocol_version: "v9.9")) ==
               ~s(Unsupported protocol version: "v9.9")
    end

    test "components must be an object of schemas" do
      document = %{"catalogId" => "x", "components" => ["Text"]}

      assert error_message(Catalog.from_json(document, protocol_version: "v1.0")) ==
               "Catalog 'components' must be an object mapping names to schemas."

      document = %{"catalogId" => "x", "components" => %{"Text" => "nope"}}

      assert error_message(Catalog.from_json(document, protocol_version: "v1.0")) ==
               "Component 'Text' schema must be a JSON schema object, got str."
    end

    test "function definitions are checked" do
      assert error_message(
               Catalog.from_json(%{"catalogId" => "x", "functions" => %{"f" => 1}},
                 protocol_version: "v1.0"
               )
             ) == "Catalog 'x' function 'f' must be a JSON schema object, got int."

      assert error_message(
               Catalog.from_json(%{"catalogId" => "x", "functions" => [%{"schema" => 1}]},
                 protocol_version: "v1.0"
               )
             ) == "Catalog 'x' function definition 0 is missing a non-empty 'name' string."

      assert error_message(
               Catalog.from_json(%{"catalogId" => "x", "functions" => ["f"]},
                 protocol_version: "v1.0"
               )
             ) == "Catalog 'x' function definition 0 must be an object, got str."

      assert error_message(
               Catalog.from_json(%{"catalogId" => "x", "functions" => "f"},
                 protocol_version: "v1.0"
               )
             ) == "Catalog 'x' 'functions' must be an object or a list of definitions, got str."
    end

    test "v1.0 names must be UAX #31 identifiers" do
      bad_component = %{"catalogId" => "x", "components" => %{"Bad Name" => %{}}}

      assert error_message(Catalog.from_json(bad_component, protocol_version: "v1.0")) ==
               "Invalid UAX #31 component identifier: 'Bad Name'"

      bad_property = %{
        "catalogId" => "x",
        "components" => %{"Text" => %{"properties" => %{"my-prop" => %{}}}}
      }

      assert error_message(Catalog.from_json(bad_property, protocol_version: "v1.0")) ==
               "Invalid UAX #31 property identifier: 'my-prop' in component 'Text'"

      bad_function = %{"catalogId" => "x", "functions" => %{"1st" => %{}}}

      assert error_message(Catalog.from_json(bad_function, protocol_version: "v1.0")) ==
               "Invalid UAX #31 function identifier: '1st'"

      bad_argument = %{
        "catalogId" => "x",
        "functions" => %{"f" => %{"properties" => %{"a b" => %{}}}}
      }

      assert error_message(Catalog.from_json(bad_argument, protocol_version: "v1.0")) ==
               "Invalid UAX #31 argument identifier: 'a b' in function 'f'"
    end

    test "identifier rules do not apply before v1.0" do
      document = %{"catalogId" => "x", "components" => %{"Bad Name" => %{"properties" => %{}}}}
      assert {:ok, _catalog} = Catalog.from_json(document, protocol_version: "v0.9")
    end

    test "from_json!/2 raises" do
      assert_raise Error, ~r/catalog_id must be provided/, fn ->
        Catalog.from_json!(%{}, protocol_version: "v1.0")
      end
    end
  end

  describe "component shaping" do
    test "v0.9 flat components declare id and component" do
      document = %{
        "catalogId" => "urn:test:v09",
        "components" => %{
          "Label" => %{
            "type" => "object",
            "properties" => %{"text" => %{"type" => "string"}},
            "required" => ["text"],
            "additionalProperties" => false
          }
        }
      }

      label =
        document
        |> Catalog.from_json!(protocol_version: "v0.9")
        |> Catalog.to_schema()
        |> get_in(["components", "Label"])

      assert label["properties"]["component"] == %{"const" => "Label"}
      assert label["properties"]["id"]["$ref"] == "#/$defs/ComponentId"
      assert label["required"] == ["id", "text", "component"]
      assert label["unevaluatedProperties"] == false
      refute Map.has_key?(label, "additionalProperties")
    end

    test "an existing component property becomes the component's const and is required" do
      document = %{
        "catalogId" => "urn:test:v1",
        "components" => %{
          "Label" => %{
            "type" => "object",
            "properties" => %{"component" => %{"type" => "string"}, "text" => %{}}
          }
        }
      }

      label =
        document
        |> Catalog.from_json!(protocol_version: "v1.0")
        |> Catalog.to_schema()
        |> get_in(["components", "Label"])

      assert label["properties"]["component"] == %{"const" => "Label"}
      assert "component" in label["required"]
    end

    test "v1.0 allOf envelopes are merged into one properties schema" do
      catalog = Catalog.from_json!(v1_document(), protocol_version: "v1.0")
      card = catalog.schema["components"]["Card"]

      refute Map.has_key?(card, "allOf")
      assert card["type"] == "object"
      assert card["required"] == ["id", "title", "component"]
      assert card["unevaluatedProperties"] == false

      assert Map.keys(card["properties"]) |> Enum.sort() ==
               ~w(accessibility child component id metadata title weight)
    end

    test "flattening keeps the parts it cannot merge" do
      conditional = %{
        "type" => "object",
        "allOf" => [
          %{"$ref" => "common_types.json#/$defs/ComponentCommon"},
          %{"if" => %{"properties" => %{"a" => %{}}}, "then" => %{"required" => ["b"]}}
        ],
        "properties" => %{"component" => %{"const" => "Odd"}}
      }

      document = %{"catalogId" => "x", "components" => %{"Odd" => conditional}}
      catalog = Catalog.from_json!(document, protocol_version: "v1.0")

      assert %{"allOf" => [%{"if" => _, "then" => _}], "properties" => properties} =
               catalog.schema["components"]["Odd"]

      assert %{"id" => _, "component" => %{"const" => "Odd"}} = properties
    end

    test "a reference that resolves nowhere is kept" do
      unknown = %{
        "type" => "object",
        "allOf" => [%{"$ref" => "#/$defs/Missing"}],
        "properties" => %{"component" => %{"const" => "Lost"}}
      }

      document = %{"catalogId" => "x", "components" => %{"Lost" => unknown}}
      catalog = Catalog.from_json!(document, protocol_version: "v1.0")

      assert %{"allOf" => [%{"$ref" => "#/$defs/Missing"}]} = catalog.schema["components"]["Lost"]
    end
  end

  describe "new/3" do
    test "assembles a catalog from parts" do
      text = Component.from_schema("Text", %{"type" => "object", "properties" => %{}})

      assert {:ok, catalog} =
               Catalog.new("urn:parts", "v1.0",
                 components: [text],
                 instructions: "hello",
                 theme: %{"type" => "object"}
               )

      assert Map.keys(catalog.components) == ["Text"]
      assert catalog.instructions == "hello"
      assert catalog.schema["catalogId"] == "urn:parts"
      assert catalog.schema["$defs"]["theme"]["type"] == "object"
      assert Catalog.to_json(catalog)["components"]["Text"] == text.schema
    end

    test "rejects unsupported versions and invalid names" do
      assert error_message(Catalog.new("x", "v9.9")) == ~s(Unsupported protocol version: "v9.9")

      bad = Component.from_schema("not valid", %{})

      assert error_message(Catalog.new("x", "v1.0", components: [bad])) ==
               "Invalid UAX #31 component identifier: 'not valid'"

      bad_function = Function.from_schema("not valid", %{})

      assert error_message(Catalog.new("x", "v1.0", functions: [bad_function])) ==
               "Invalid UAX #31 function identifier: 'not valid'"
    end

    test "new!/3 raises" do
      assert_raise Error, fn -> Catalog.new!("x", "v9.9") end
    end
  end

  describe "derive/3" do
    setup do
      {:ok, catalog: Catalog.from_json!(v1_document(), protocol_version: "v1.0")}
    end

    test "copies under a new id", %{catalog: catalog} do
      derived = Catalog.derive(catalog, "urn:derived")

      assert derived.catalog_id == "urn:derived"
      assert derived.schema["catalogId"] == "urn:derived"
      assert Map.keys(derived.components) == ["Card"]
      assert Map.keys(derived.functions) == ["double"]
    end

    test "can drop the functions", %{catalog: catalog} do
      derived = Catalog.derive(catalog, "urn:derived", functions: false)

      assert derived.functions == %{}
      refute Map.has_key?(derived.schema, "functions")
    end
  end

  describe "lookups" do
    setup do
      document = v1_document(%{"functions" => %{"formatString" => @double, "Upper" => @double}})
      {:ok, catalog: Catalog.from_json!(document, protocol_version: "v1.0")}
    end

    test "get_component/2", %{catalog: catalog} do
      assert %Component{name: "Card"} = Catalog.get_component(catalog, "Card")
      assert Catalog.get_component(catalog, "Missing") == nil
      assert Catalog.get_component(catalog, nil) == nil
      assert Catalog.get_component(catalog, 7) == nil
    end

    test "get_function/2 matches the first letter in either case", %{catalog: catalog} do
      assert %Function{name: "formatString"} = Catalog.get_function(catalog, "formatString")
      assert %Function{name: "formatString"} = Catalog.get_function(catalog, "FormatString")
      assert %Function{name: "Upper"} = Catalog.get_function(catalog, "upper")
      assert Catalog.get_function(catalog, "missing") == nil
      assert Catalog.get_function(catalog, "") == nil
      assert Catalog.get_function(catalog, nil) == nil
    end

    test "ref_spec/2", %{catalog: catalog} do
      assert Catalog.ref_spec(catalog, "Card") != nil
      assert Catalog.ref_spec(catalog, "Missing") == nil
    end
  end

  describe "put_implementations/2" do
    test "attaches implementations by name and ignores unknown names" do
      catalog = Catalog.from_json!(v1_document(), protocol_version: "v1.0")
      execute = fn args, _context -> {:ok, args["value"] * 2} end

      catalog = Catalog.put_implementations(catalog, %{"double" => execute, "ghost" => execute})

      assert catalog.functions["double"].execute == execute
      refute Map.has_key?(catalog.functions, "ghost")
    end
  end

  describe "common_definitions/1" do
    test "returns localized definitions for supported versions" do
      defs = Catalog.common_definitions("v1.0")

      assert %{"$ref" => "#/$defs/DynamicString"} =
               defs["AccessibilityAttributes"]["properties"]["label"] |> Map.take(["$ref"])
    end

    test "is empty for unsupported versions" do
      assert Catalog.common_definitions("v9.9") == %{}
      assert Catalog.common_definitions("nonsense") == %{}
    end
  end

  describe "peer catalogs" do
    setup do
      peer =
        Catalog.from_json!(
          %{
            "$id" => "https://acme.test/catalogs/widgets.json",
            "catalogId" => "acme/widgets",
            "components" => %{
              "Badge" => %{
                "type" => "object",
                "properties" => %{
                  "component" => %{"const" => "Badge"},
                  "label" => %{"$ref" => "#/$defs/Label"}
                },
                "required" => ["component", "label"]
              }
            },
            "$defs" => %{"Label" => %{"type" => "string", "maxLength" => 20}}
          },
          protocol_version: "v1.0"
        )

      user =
        Catalog.from_json!(
          %{
            "catalogId" => "acme/app",
            "components" => %{"Tag" => %{"$ref" => "widgets.json#/components/Badge"}}
          },
          protocol_version: "v1.0"
        )

      {:ok, peer: peer, user: user}
    end

    @badge %{
      "type" => "object",
      "properties" => %{"label" => %{"type" => "string", "maxLength" => 20}},
      "required" => ["label"]
    }

    test "a reference into a peer resolves once the catalogs are linked", %{
      peer: peer,
      user: user
    } do
      assert Catalog.cross_document?(user)
      refute Catalog.cross_document?(peer)

      assert Catalog.resolved_component_schema(user, "Tag") ==
               %{"$ref" => "widgets.json#/components/Badge"}

      linked = Catalog.with_peer_catalogs(user, [peer])

      assert [%Catalog{catalog_id: "acme/widgets", peers: []}] = linked.peers
      assert Catalog.resolved_component_schema(linked, "Tag") == @badge
      assert Catalog.to_json(linked) == Catalog.to_json(user)

      label = %{"$ref" => "acme/widgets#/components/Badge/properties/label"}

      assert Catalog.inline_refs(linked, label, Catalog.to_json(linked)) ==
               %{"type" => "string", "maxLength" => 20}
    end

    test "linking adds each peer once and never the catalog itself", %{peer: peer, user: user} do
      linked = Catalog.with_peer_catalogs(user, [peer])

      assert Catalog.with_peer_catalogs(linked, [peer]) == linked
      assert Catalog.with_peer_catalogs(user, [user, :not_a_catalog]) == user
    end

    test "a pruned peer brings the catalog it was pruned from", %{peer: peer, user: user} do
      pruned = Catalog.copy_with(peer, components: [])
      linked = Catalog.with_peer_catalogs(user, [pruned])

      assert Enum.map(linked.peers, & &1.component_order) == [["Badge"], []]
      assert Catalog.resolved_component_schema(linked, "Tag") == @badge
    end

    test "link_catalogs/2 links the catalogs that reference others", %{peer: peer, user: user} do
      assert [linked, ^peer] = Catalog.link_catalogs([user, peer])
      assert Catalog.resolved_component_schema(linked, "Tag") == @badge

      assert Catalog.link_catalogs([user]) == [user]
      assert [extra_linked] = Catalog.link_catalogs([user], [peer])
      assert Catalog.resolved_component_schema(extra_linked, "Tag") == @badge
    end
  end

  describe "copy_with/2" do
    test "an authored union that no longer lists the entries is derived again" do
      document =
        v1_document(%{
          "components" => %{"Card" => @card, "Other" => @card},
          "$defs" => %{
            "CatalogComponentCommon" => %{"type" => "object"},
            "anyComponent" => %{
              "description" => "authored",
              "oneOf" => [%{"$ref" => "#/components/Card"}, %{"$ref" => "#/components/Other"}]
            }
          }
        })

      catalog = Catalog.from_json!(document, protocol_version: "v1.0")
      assert Catalog.to_json(catalog)["$defs"]["anyComponent"]["description"] == "authored"

      copy = Catalog.copy_with(catalog, components: [catalog.components["Card"]])

      assert Catalog.to_json(copy)["$defs"]["anyComponent"] == %{
               "oneOf" => [%{"$ref" => "#/components/Card"}],
               "discriminator" => %{"propertyName" => "component"}
             }
    end

    test "a catalog defined in code is copied with its derived unions" do
      text = Component.from_schema("Text", %{"type" => "object"})
      catalog = Catalog.new!("x", "v1.0", components: [text], defs: %{"Unused" => %{}})
      copy = Catalog.copy_with(catalog, components: [])

      assert copy.components == %{}
      assert Catalog.to_json(copy)["$defs"]["anyComponent"] == %{"not" => %{}}
      assert Map.has_key?(copy.defs, "Unused")
    end
  end

  describe "to_json/2" do
    test "ordered: true writes the document in the order it was read" do
      text =
        ~s({"catalogId": "x", "protocolVersion": "1.0", "title": "T", "components": ) <>
          ~s({"Z": {"type": "object", "properties": {"component": {"const": "Z"}}}, ) <>
          ~s("A": {"properties": {"component": {"const": "A"}}, "type": "object"}}})

      catalog = text |> Jason.decode!(objects: :ordered_objects) |> Catalog.from_json!()

      assert catalog |> Catalog.to_json(ordered: true) |> Jason.encode!() ==
               ~s({"protocolVersion":"1.0","title":"T","catalogId":"x","components":) <>
                 ~s({"Z":{"type":"object","properties":{"component":{"const":"Z"}}},) <>
                 ~s("A":{"properties":{"component":{"const":"A"}},"type":"object"}}})

      pruned = Catalog.copy_with(catalog, components: [catalog.components["A"]])

      assert pruned |> Catalog.to_json(ordered: true) |> Jason.encode!() ==
               ~s({"protocolVersion":"1.0","title":"T","catalogId":"x","components":) <>
                 ~s({"A":{"properties":{"component":{"const":"A"}},"type":"object"}}})

      code = Catalog.new!("y", "v1.0", components: [catalog.components["Z"]])

      assert code |> Catalog.to_json(ordered: true) |> Jason.encode!() ==
               ~s({"$schema":"https://json-schema.org/draft/2020-12/schema",) <>
                 ~s("protocolVersion":"1.0","catalogId":"y","components":) <>
                 ~s({"Z":{"properties":{"component":{"const":"Z"}},"type":"object"}},) <>
                 ~s("$defs":{"anyComponent":{"oneOf":[{"$ref":"#/components/Z"}],) <>
                 ~s("discriminator":{"propertyName":"component"}},"anyFunction":{"not":{}}}})

      assert Catalog.to_json(catalog) ==
               catalog |> Catalog.to_json(ordered: true) |> A2UICore.KeyOrder.to_plain()
    end
  end

  describe "localize/1" do
    test "rewrites only references into common_types.json and catalog.json" do
      node = %{
        "a" => %{"$ref" => "common_types.json#/$defs/ComponentId"},
        "b" => [
          %{"$ref" => "https://a2ui.org/specification/v1_0/catalog.json#/$defs/anyFunction"}
        ],
        "c" => %{"$ref" => "other.json#/$defs/Thing"},
        "d" => %{"$ref" => "#/$defs/Local"},
        "e" => %{"$ref" => "common_types.json"},
        "f" => 3
      }

      assert Catalog.localize(node) == %{
               "a" => %{"$ref" => "#/$defs/ComponentId"},
               "b" => [%{"$ref" => "#/$defs/anyFunction"}],
               "c" => %{"$ref" => "other.json#/$defs/Thing"},
               "d" => %{"$ref" => "#/$defs/Local"},
               "e" => %{"$ref" => "common_types.json"},
               "f" => 3
             }
    end
  end

  defp refs(%{"$ref" => ref} = node), do: [ref | node |> Map.delete("$ref") |> refs()]
  defp refs(%{} = node), do: Enum.flat_map(node, fn {_key, value} -> refs(value) end)
  defp refs(list) when is_list(list), do: Enum.flat_map(list, &refs/1)
  defp refs(_other), do: []
end

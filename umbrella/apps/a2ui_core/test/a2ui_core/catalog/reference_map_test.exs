defmodule A2UICore.Catalog.ReferenceMapTest do
  @moduledoc false
  use ExUnit.Case, async: true

  alias A2UICore.Catalog.{ReferenceMap, RefSpec}

  @id_ref "https://a2ui.org/specification/v1_0/common_types.json#/$defs/ComponentId"
  @child_ref "common_types.json#/$defs/Child"
  @list_ref "common_types.json#/$defs/ChildList"

  defp catalog(name), do: ReferenceMap.build(load(name))

  defp load(name) do
    :a2ui_core
    |> Application.app_dir("priv/catalogs/#{name}.json")
    |> File.read!()
    |> Jason.decode!()
  end

  defp parts(%RefSpec{} = spec) do
    {spec.single |> MapSet.to_list() |> Enum.sort(), spec.list |> MapSet.to_list() |> Enum.sort(),
     Map.new(spec.nested, fn {key, items} -> {key, items |> MapSet.to_list() |> Enum.sort()} end)}
  end

  describe "the vendored basic catalogs" do
    for name <- ["basic_v0_9_1", "basic_v1_0"] do
      test "#{name}: container and single-child components" do
        specs = catalog(unquote(name))

        assert parts(specs["Row"]) == {[], ["children"], %{}}
        assert parts(specs["Column"]) == {[], ["children"], %{}}
        assert parts(specs["List"]) == {[], ["children"], %{}}
        assert parts(specs["Card"]) == {["child"], [], %{}}
        assert parts(specs["Button"]) == {["child"], [], %{}}
        assert parts(specs["Modal"]) == {["content", "trigger"], [], %{}}
      end

      test "#{name}: Tabs nest the child under each tab" do
        assert parts(catalog(unquote(name))["Tabs"]) == {[], ["tabs"], %{"tabs" => ["child"]}}
      end

      test "#{name}: leaf components have no child references" do
        specs = catalog(unquote(name))

        for leaf <- ["Text", "Image", "Icon", "Divider", "TextField", "Slider"] do
          assert RefSpec.empty?(specs[leaf]), "#{leaf} should be a leaf"
        end
      end
    end

    test "every component of the catalog gets a spec" do
      specs = catalog("basic_v1_0")
      assert map_size(specs) == 18
    end
  end

  describe "analyze/2" do
    test "a $ref to ComponentId or Child is a single reference" do
      schema = %{
        "properties" => %{
          "a" => %{"$ref" => @id_ref},
          "b" => %{"$ref" => @child_ref}
        }
      }

      assert parts(ReferenceMap.analyze(schema)) == {["a", "b"], [], %{}}
    end

    test "a $ref to ChildList is a list reference" do
      schema = %{"properties" => %{"kids" => %{"$ref" => @list_ref}}}
      assert parts(ReferenceMap.analyze(schema)) == {[], ["kids"], %{}}
    end

    test "references are found through allOf, anyOf and oneOf" do
      schema = %{
        "allOf" => [
          %{"properties" => %{"a" => %{"$ref" => @child_ref}}},
          %{"anyOf" => [%{"properties" => %{"b" => %{"oneOf" => [%{"$ref" => @id_ref}]}}}]}
        ]
      }

      assert parts(ReferenceMap.analyze(schema)) == {["a", "b"], [], %{}}
    end

    test "template-shaped objects are lists" do
      schema = %{
        "properties" => %{
          "explicit" => %{"type" => "object", "properties" => %{"explicitList" => %{}}},
          "templated" => %{
            "type" => "object",
            "properties" => %{"componentId" => %{}, "path" => %{}}
          },
          "bound" => %{
            "type" => "object",
            "properties" => %{"componentId" => %{}, "dataBinding" => %{}}
          }
        }
      }

      assert parts(ReferenceMap.analyze(schema)) == {[], ["bound", "explicit", "templated"], %{}}
    end

    test "an array of child references is a list" do
      schema = %{
        "properties" => %{"items" => %{"type" => "array", "items" => %{"$ref" => @id_ref}}}
      }

      assert parts(ReferenceMap.analyze(schema)) == {[], ["items"], %{}}
    end

    test "an array of objects with a child slot is a nested list" do
      schema = %{
        "properties" => %{
          "sections" => %{
            "type" => "array",
            "items" => %{
              "type" => "object",
              "properties" => %{
                "title" => %{"type" => "string"},
                "body" => %{"$ref" => @child_ref}
              }
            }
          }
        }
      }

      assert parts(ReferenceMap.analyze(schema)) == {[], ["sections"], %{"sections" => ["body"]}}
    end

    test "local $refs are followed through the component's $defs and the catalog" do
      catalog = %{
        "$defs" => %{
          "Slot" => %{"$ref" => @id_ref},
          "Section" => %{"type" => "object", "properties" => %{"body" => %{"$ref" => @child_ref}}}
        }
      }

      schema = %{
        "$defs" => %{"Local" => %{"$ref" => @child_ref}},
        "properties" => %{
          "viaCatalog" => %{"$ref" => "#/$defs/Slot"},
          "viaItems" => %{"type" => "array", "items" => %{"$ref" => "#/$defs/Section"}}
        }
      }

      # Array items are dereferenced, so `viaItems` is a nested list. A bare
      # property that aliases a ComponentId def (`viaCatalog`) is classified
      # by its own `$ref` name only, as in the reference.
      spec = ReferenceMap.analyze(schema, catalog)
      assert parts(spec) == {[], ["viaItems"], %{"viaItems" => ["body"]}}
    end

    test "a component schema that is itself a $ref is expanded" do
      catalog = %{
        "$defs" => %{"Base" => %{"properties" => %{"child" => %{"$ref" => @child_ref}}}}
      }

      assert parts(ReferenceMap.analyze(%{"$ref" => "#/$defs/Base"}, catalog)) ==
               {["child"], [], %{}}
    end

    test "a cyclic $ref terminates" do
      catalog = %{
        "$defs" => %{
          "A" => %{
            "$ref" => "#/$defs/A",
            "allOf" => [%{"$ref" => "#/$defs/B"}],
            "properties" => %{"child" => %{"$ref" => @child_ref}}
          },
          "B" => %{"$ref" => "#/$defs/A"}
        }
      }

      assert parts(ReferenceMap.analyze(%{"$ref" => "#/$defs/A"}, catalog)) ==
               {["child"], [], %{}}
    end

    test "unresolvable and external $refs are ignored" do
      schema = %{
        "$ref" => "#/$defs/Missing",
        "properties" => %{"x" => %{"$ref" => "https://example.test/x.json#/$defs/Y"}}
      }

      assert RefSpec.empty?(ReferenceMap.analyze(schema, %{}))
    end

    test "id and component are never child properties" do
      schema = %{
        "properties" => %{
          "id" => %{"$ref" => @id_ref},
          "component" => %{"$ref" => @id_ref}
        }
      }

      assert RefSpec.empty?(ReferenceMap.analyze(schema))
    end

    test "non-schema input yields an empty spec" do
      assert RefSpec.empty?(ReferenceMap.analyze(true))
      assert RefSpec.empty?(ReferenceMap.analyze(nil))
    end
  end

  describe "build/1" do
    test "a document without components yields no specs" do
      assert ReferenceMap.build(%{}) == %{}
      assert ReferenceMap.build(%{"components" => []}) == %{}
    end

    test "resolves refs against the enclosing document" do
      document = %{
        "$defs" => %{"Slot" => %{"$ref" => @id_ref}},
        "components" => %{
          "Frame" => %{"properties" => %{"inner" => %{"$ref" => @id_ref}}},
          "Plain" => %{"properties" => %{"label" => %{"type" => "string"}}}
        }
      }

      specs = ReferenceMap.build(document)
      assert parts(specs["Frame"]) == {["inner"], [], %{}}
      assert RefSpec.empty?(specs["Plain"])
    end
  end
end

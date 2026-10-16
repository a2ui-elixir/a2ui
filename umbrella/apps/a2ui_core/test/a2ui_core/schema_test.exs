defmodule A2UICore.SchemaTest do
  @moduledoc false
  use ExUnit.Case, async: true

  alias A2UICore.Schema

  defp assert_ok(data, schema, opts \\ []) do
    assert Schema.validate(data, schema, opts) == :ok
  end

  defp assert_error(data, schema, opts \\ []) do
    assert {:error, details} = Schema.validate(data, schema, opts)
    details
  end

  describe "boolean schemas" do
    test "true allows anything" do
      assert_ok(%{any: "thing"}, true)
      assert_ok(nil, true)
      assert_ok(42, true)
    end

    test "false allows nothing" do
      assert [%{code: "invalid_value"}] = assert_error(%{}, false)
    end

    test "empty schema allows anything" do
      assert_ok("x", %{})
    end
  end

  describe "type" do
    test "string" do
      assert_ok("hello", %{"type" => "string"})
      assert [%{code: "type_mismatch", message: msg}] = assert_error(42, %{"type" => "string"})
      assert msg =~ "is not of type 'string'"
    end

    test "integer accepts floats with zero fraction (2020-12 rule)" do
      assert_ok(1, %{"type" => "integer"})
      assert_ok(1.0, %{"type" => "integer"})
      assert_error(1.5, %{"type" => "integer"})
    end

    test "number rejects booleans" do
      assert_error(true, %{"type" => "number"})
      assert_ok(true, %{"type" => "boolean"})
    end

    test "type lists" do
      assert_ok(5, %{"type" => ["string", "number"]})
      assert_error(nil, %{"type" => ["string", "number"]})
      assert_ok(nil, %{"type" => ["string", "null"]})
    end

    test "null" do
      assert_ok(nil, %{"type" => "null"})
      assert_error("", %{"type" => "null"})
    end

    test "object vs struct" do
      assert_ok(%{}, %{"type" => "object"})
      assert_error({:a, :b}, %{"type" => "object"})
    end
  end

  describe "const and enum (JSON equality)" do
    test "const with numeric equality 1 == 1.0" do
      assert_ok(1.0, %{"const" => 1})
      assert_ok(1, %{"const" => 1.0})
      assert [%{code: "invalid_value"}] = assert_error(2, %{"const" => 1})
    end

    test "enum membership" do
      assert_ok("doughnut", %{"enum" => ["doughnut", "pie"]})

      assert [%{code: "type_mismatch", message: msg}] =
               assert_error("bar", %{"enum" => ["doughnut", "pie"]})

      assert msg =~ "is not one of"
    end

    test "deep equality for maps and lists" do
      assert_ok(%{"a" => [1, 2]}, %{"const" => %{"a" => [1.0, 2.0]}})
    end
  end

  describe "strings" do
    test "minLength / maxLength count codepoints" do
      assert_ok("ab", %{"minLength" => 2})
      assert_error("a", %{"minLength" => 2})
      assert_ok("ab", %{"maxLength" => 2})
      assert_error("abc", %{"maxLength" => 2})
    end

    test "pattern is an unanchored search" do
      assert_ok("hello world", %{"pattern" => "wor"})
    end

    test "pattern is ECMA-262: unescaped $ is an absolute anchor" do
      # PCRE `$` would match before the trailing newline; ECMA/JSON-Schema
      # semantics (via the reference's \\Z rewrite) must reject "123\\n".
      assert_ok("123", %{"pattern" => "^[0-9]+$"})
      assert_error("123\n", %{"pattern" => "^[0-9]+$"})

      # escaped $ stays literal
      assert_ok("5$", %{"pattern" => "5\\$"})
    end

    test "pattern with XID unicode properties" do
      pattern = "^[\\p{XID_Start}_][\\p{XID_Continue}]*$"
      assert_ok("Component_ℓ", %{"pattern" => pattern})
      assert_error("1stItem", %{"pattern" => pattern})
      assert_error("submit-form", %{"pattern" => pattern})
    end

    test "pattern XID properties are exact (UAX #31, as Python's isidentifier)" do
      pattern = "^[\\p{XID_Start}_][\\p{XID_Continue}]*$"
      assert_ok("℘map", %{"pattern" => pattern})
      assert_ok("a·b", %{"pattern" => pattern})
      assert_error("·a", %{"pattern" => pattern})
      assert_error("゛a", %{"pattern" => pattern})
    end

    test "pattern Unicode property escapes take ECMA-262 names" do
      assert_ok("Hello", %{"pattern" => "^\\p{Letter}+$"})
      assert_ok("Привет", %{"pattern" => "^\\p{Letter}+$"})
      assert_error("x1", %{"pattern" => "^\\p{Letter}+$"})
      assert_ok("1-2", %{"pattern" => "^\\P{Letter}+$"})
      assert_ok("Ab", %{"pattern" => "^\\p{General_Category=Uppercase_Letter}\\p{gc=Ll}$"})
      assert_error("ab", %{"pattern" => "^\\p{Lu}"})
      assert_ok("Ab", %{"pattern" => "^[\\p{Cased_Letter}\\d]+$"})
      assert_ok("x", %{"pattern" => "^\\p{Assigned}$"})
      assert_error("x", %{"pattern" => "^\\P{Assigned}$"})
      assert_ok("αβ", %{"pattern" => "^\\p{Script=Greek}+$"})
      assert_error("ab", %{"pattern" => "^\\p{sc=Grek}+$"})
      assert [%{code: "invalid_value"}] = assert_error("x", %{"pattern" => "\\p{Letter"})
    end

    test "pattern character classes and escapes are ECMA-262's" do
      assert_error("߀", %{"pattern" => "^\\d$"})
      assert_ok("߀", %{"pattern" => "^\\D$"})
      assert_error("é", %{"pattern" => "^\\w$"})
      assert_ok("é", %{"pattern" => "^\\W$"})
      assert_ok(<<0xFEFF::utf8>>, %{"pattern" => "^\\s$"})
      assert_ok(<<0xFEFF::utf8>>, %{"pattern" => "^[\\s]$"})
      assert_error(<<0xFEFF::utf8>>, %{"pattern" => "^\\S$"})
      assert_ok("a", %{"pattern" => "^[\\S]$"})
      assert_ok(<<0x0B>>, %{"pattern" => "^\\v$"})
      assert_error("\n", %{"pattern" => "^\\v$"})
      assert_ok("a", %{"pattern" => "^.$"})
      assert_error("\r", %{"pattern" => "^.$"})
      assert_ok(".", %{"pattern" => "^[.]$"})
    end

    test "pattern unicode escapes become code points" do
      bs = <<92>>
      assert_ok("A", %{"pattern" => "^" <> bs <> "u0041$"})
      assert_ok("😀", %{"pattern" => "^" <> bs <> "u{1F600}$"})
      assert_ok("😀", %{"pattern" => "^" <> bs <> "uD83D" <> bs <> "uDE00$"})
      assert [%{code: "invalid_value"}] = assert_error("x", %{"pattern" => bs <> "u{zz}"})
      assert [%{code: "invalid_value"}] = assert_error("x", %{"pattern" => bs <> "uzzzz"})
      assert [%{code: "invalid_value"}] = assert_error("x", %{"pattern" => bs <> "uD83Dx"})

      assert [%{code: "invalid_value"}] =
               assert_error("x", %{"pattern" => bs <> "uD83D" <> bs <> "u0041"})
    end

    test "invalid pattern is an invalid_value error, not a silent pass" do
      assert [%{code: "invalid_value"}] = assert_error("x", %{"pattern" => "([unclosed"})
    end
  end

  describe "numbers" do
    test "bounds" do
      assert_ok(5, %{"minimum" => 5})
      assert_error(4, %{"minimum" => 5})
      assert_ok(5, %{"maximum" => 5})
      assert_error(6, %{"maximum" => 5})
      assert_error(5, %{"exclusiveMinimum" => 5})
      assert_ok(5.1, %{"exclusiveMinimum" => 5})
      assert_error(5, %{"exclusiveMaximum" => 5})
    end

    test "multipleOf" do
      assert_ok(9, %{"multipleOf" => 3})
      assert_error(10, %{"multipleOf" => 3})
      assert_ok(12_345_678_901_234_567_890, %{"multipleOf" => 10})
      assert_ok(0.3, %{"multipleOf" => 0.1})
    end

    test "multipleOf with a quotient too large for a float uses the remainder" do
      assert_ok(1.0e308, %{"multipleOf" => 0.5})
      assert_error(1.0e308, %{"multipleOf" => 0.123456789})
    end

    test "decimal limits count like integers" do
      assert_ok("ab", %{"maxLength" => 2.0})
      assert_error("abc", %{"maxLength" => 2.0})
      assert_error([1], %{"minItems" => 2.0})
      assert_error([1, 2, 3], %{"maxItems" => 2.0})
    end
  end

  describe "objects" do
    test "required produces missing_field with the property in the path" do
      details = assert_error(%{"a" => 1}, %{"required" => ["a", "b"]})

      assert [%{code: "missing_field", path: "b", message: "'b' is a required property"}] =
               details
    end

    test "properties descend and annotate" do
      schema = %{"properties" => %{"text" => %{"type" => "string"}}}
      assert_ok(%{"text" => "hi"}, schema)
      assert [%{code: "type_mismatch", path: "text"}] = assert_error(%{"text" => 5}, schema)
    end

    test "additionalProperties false (message matches the reference)" do
      schema = %{"properties" => %{"a" => %{}}, "additionalProperties" => false}
      assert_ok(%{"a" => 1}, schema)

      assert [%{code: "extra_field", message: msg}] =
               assert_error(%{"a" => 1, "zz" => 2}, schema)

      assert msg == "Additional properties are not allowed ('zz' was unexpected)"
    end

    test "additionalProperties false with patternProperties uses the regex message" do
      schema = %{
        "patternProperties" => %{"^x-" => %{}},
        "additionalProperties" => false
      }

      assert_ok(%{"x-a" => 1}, schema)

      assert [%{message: msg}] = assert_error(%{"x-a" => 1, "b" => 2, "c" => 3}, schema)
      assert msg == "'b', 'c' do not match any of the regexes: '^x-'"
    end

    test "additionalProperties schema descends into extras" do
      schema = %{
        "properties" => %{"a" => %{}},
        "additionalProperties" => %{"type" => "integer"}
      }

      assert_ok(%{"a" => 1, "extra" => 2}, schema)

      assert [%{code: "type_mismatch", path: "extra"}] =
               assert_error(%{"a" => 1, "extra" => "no"}, schema)
    end

    test "propertyNames validates every key" do
      schema = %{"propertyNames" => %{"pattern" => "^[a-z]+$"}}
      assert_ok(%{"abc" => 1}, schema)
      assert [%{path: "ABC"}] = assert_error(%{"ABC" => 1}, schema)
    end

    test "propertyNames with not (the Surface ban)" do
      schema = %{"propertyNames" => %{"not" => %{"const" => "Surface"}}}
      assert_ok(%{"Text" => %{}}, schema)

      assert [%{code: "invalid_value", path: "Surface"}] =
               assert_error(%{"Surface" => %{}}, schema)
    end

    test "dependentRequired" do
      schema = %{"dependentRequired" => %{"card" => ["billing"]}}
      assert_ok(%{"name" => "x"}, schema)
      assert_ok(%{"card" => 1, "billing" => 2}, schema)

      assert [%{code: "missing_field", path: "billing", message: message}] =
               assert_error(%{"card" => 1}, schema)

      assert message == "'billing' is a dependency of 'card'"
    end

    test "dependentSchemas apply when the property is present, and annotate" do
      schema = %{
        "properties" => %{"card" => true},
        "dependentSchemas" => %{
          "card" => %{"properties" => %{"billing" => %{"type" => "string"}}}
        },
        "unevaluatedProperties" => false
      }

      assert_ok(%{"card" => 1, "billing" => "x"}, schema)
      # A failing dependent schema contributes no annotations either.
      assert [%{code: "type_mismatch", path: "billing"}, %{code: "extra_field"}] =
               assert_error(%{"card" => 1, "billing" => 2}, schema)

      assert [%{code: "extra_field"}] = assert_error(%{"billing" => "x"}, schema)
      assert_ok("not an object", schema)
    end

    test "minProperties / maxProperties" do
      assert_error(%{"a" => 1}, %{"minProperties" => 2})
      assert_ok(%{"a" => 1, "b" => 2}, %{"minProperties" => 2})
      assert_error(%{"a" => 1, "b" => 2}, %{"maxProperties" => 1})
    end
  end

  describe "arrays" do
    test "items over all elements" do
      schema = %{"type" => "array", "items" => %{"type" => "integer"}}
      assert_ok([1, 2, 3], schema)
      assert [%{code: "type_mismatch", path: "1"}] = assert_error([1, "x"], schema)
    end

    test "prefixItems tuple validation plus items for the rest" do
      schema = %{
        "prefixItems" => [%{"type" => "string"}, %{"type" => "integer"}],
        "items" => %{"type" => "boolean"}
      }

      assert_ok(["a", 1, true, false], schema)
      assert [%{path: "0", code: "type_mismatch"} | _] = assert_error([1, "a"], schema)
      assert [%{path: "2", code: "type_mismatch"} | _] = assert_error(["a", 1, "x"], schema)
    end

    test "items false rejects elements beyond prefixItems" do
      schema = %{"prefixItems" => [%{"const" => "a"}], "items" => false}
      assert_ok(["a"], schema)
      assert_error(["a", "b"], schema)
    end

    test "minItems / maxItems / uniqueItems / contains" do
      assert_error([], %{"minItems" => 1})
      assert_error([1, 2, 3], %{"maxItems" => 2})
      assert_error([1, 1], %{"uniqueItems" => true})
      assert_ok([1, 2], %{"uniqueItems" => true})
      assert_ok(["@call"], %{"contains" => %{"const" => "@call"}})
      assert_error(["x"], %{"contains" => %{"const" => "@call"}})
    end

    test "minContains / maxContains bound the matches" do
      schema = %{"contains" => %{"const" => 1}, "minContains" => 2, "maxContains" => 3}
      assert_ok([1, 1, 2], schema)
      assert [%{message: message}] = assert_error([1, 2], schema)
      assert message =~ "too few matching elements (minimum 2)"
      assert [%{message: message}] = assert_error([1, 1, 1, 1], schema)
      assert message =~ "too many matching elements (maximum 3)"
      assert_ok([], %{"contains" => %{"const" => 1}, "minContains" => 0})
    end

    test "unevaluatedItems sees prefixItems, items, contains and applicators" do
      assert [%{message: message}] = assert_error([1, 2], %{"unevaluatedItems" => false})
      assert message == "Unevaluated items are not allowed (0, 1 unexpected)"
      assert_ok([], %{"unevaluatedItems" => false})
      assert_ok([1], %{"unevaluatedItems" => true})

      prefixed = %{"prefixItems" => [true], "unevaluatedItems" => %{"type" => "string"}}
      assert_ok([1, "a"], prefixed)
      assert [%{path: "1"}] = assert_error([1, 2], prefixed)

      contains = %{"contains" => %{"type" => "string"}, "unevaluatedItems" => false}
      assert_ok(["a", "b"], contains)
      assert_error(["a", 1], contains)

      nested = %{"allOf" => [%{"prefixItems" => [true]}], "unevaluatedItems" => false}
      assert_ok([1], nested)
      assert_error([1, 2], nested)
      assert_ok(%{}, nested)
    end
  end

  describe "combinators" do
    test "allOf merges assertions" do
      schema = %{
        "allOf" => [
          %{"type" => "object"},
          %{"properties" => %{"a" => %{"type" => "integer"}}}
        ]
      }

      assert_ok(%{"a" => 1}, schema)
      assert_error(%{"a" => "x"}, schema)
    end

    test "anyOf passes on one match, errors when none match" do
      schema = %{
        "anyOf" => [
          %{"type" => "string"},
          %{"type" => "integer"}
        ]
      }

      assert_ok("x", schema)
      assert_ok(5, schema)

      details = assert_error(true, schema)
      assert [%{code: "invalid_value", message: msg} | _] = details
      assert msg =~ "is not valid under any of the given schemas"
    end

    test "oneOf requires exactly one match" do
      schema = %{
        "oneOf" => [
          %{"type" => "integer"},
          %{"type" => "string"}
        ]
      }

      assert_ok(1, schema)
      assert_ok("a", schema)

      details = assert_error(true, schema)

      assert Enum.any?(details, fn d ->
               d.code == "invalid_value" and
                 String.contains?(d.message, "is not valid under any of the given schemas")
             end)

      both = %{"oneOf" => [%{"type" => "integer"}, %{"minimum" => 0}]}
      assert [%{message: msg} | _] = assert_error(5, both)
      assert msg =~ "is valid under each of the given schemas"
    end

    test "not" do
      assert_ok(5, %{"not" => %{"type" => "string"}})
      assert [%{code: "invalid_value"}] = assert_error("x", %{"not" => %{"type" => "string"}})
    end

    test "if/then/else (catalog FunctionDefinition pattern)" do
      # requiresUserActivation=true forces allowedCallers=rendererOnly.
      schema = %{
        "if" => %{
          "properties" => %{"requiresUserActivation" => %{"const" => true}},
          "required" => ["requiresUserActivation"]
        },
        "then" => %{
          "properties" => %{"allowedCallers" => %{"const" => "rendererOnly"}},
          "required" => ["allowedCallers"]
        },
        "else" => %{"properties" => %{"allowedCallers" => %{"const" => "agentOnly"}}}
      }

      assert_ok(%{"requiresUserActivation" => true, "allowedCallers" => "rendererOnly"}, schema)

      assert [%{code: "missing_field", path: "allowedCallers"}] =
               assert_error(%{"requiresUserActivation" => true}, schema)

      assert_ok(%{"requiresUserActivation" => false, "allowedCallers" => "agentOnly"}, schema)
    end
  end

  describe "$ref resolution" do
    test "local pointer into the root document" do
      schema = %{"$ref" => "#/$defs/point"}
      registry = %{"$root" => %{"$defs" => %{"point" => %{"type" => "object"}}}}
      assert_ok(%{}, schema, root: registry["$root"])
    end

    test "external document refs (common_types.json)" do
      schema = %{"$ref" => "common_types.json#/$defs/DynamicString"}

      registry = %{
        "common_types.json" => %{"$defs" => %{"DynamicString" => %{"type" => "string"}}}
      }

      assert_ok("hi", schema, registry: registry, root: registry["common_types.json"])
      assert_error(5, schema, registry: registry, root: registry["common_types.json"])
    end

    test "catalog.json placeholder maps to the active catalog" do
      catalog = %{"$defs" => %{"anyComponent" => %{"oneOf" => [%{"const" => "Text"}]}}}
      schema = %{"$ref" => "catalog.json#/$defs/anyComponent"}
      assert_ok("Text", schema, registry: %{"catalog.json" => catalog}, root: catalog)
    end

    test "URL basename matching" do
      registry = %{
        "https://a2ui.org/specification/v1_0/common_types.json" => %{
          "$defs" => %{"X" => %{"type" => "null"}}
        }
      }

      assert_ok(nil, %{"$ref" => "common_types.json#/$defs/X"},
        registry: registry,
        root: registry["https://a2ui.org/specification/v1_0/common_types.json"]
      )
    end

    test "nested local refs resolve against the resolved document, not the caller" do
      common = %{
        "$defs" => %{
          "A" => %{"$ref" => "#/$defs/B"},
          "B" => %{"type" => "string"}
        }
      }

      registry = %{
        "common_types.json" => common,
        "catalog.json" => %{"$defs" => %{"C" => %{"$ref" => "common_types.json#/$defs/A"}}}
      }

      assert_ok("hi", %{"$ref" => "catalog.json#/$defs/C"},
        registry: registry,
        root: registry["catalog.json"]
      )
    end

    test "unresolvable ref yields invalid_reference" do
      assert [%{code: "invalid_reference"}] =
               assert_error(1, %{"$ref" => "missing.json#/$defs/X"})
    end

    test "$ref annotations count for unevaluatedProperties" do
      root = %{
        "$defs" => %{"base" => %{"properties" => %{"a" => true}}},
        "$ref" => "#/$defs/base",
        "unevaluatedProperties" => false
      }

      assert_ok(%{"a" => 1}, root)
      assert [%{code: "extra_field"}] = assert_error(%{"a" => 1, "b" => 2}, root)
    end

    test "$id sets the base URI, and embedded resources resolve by it" do
      schema = %{
        "$id" => "https://example.com/root.json",
        "$defs" => %{
          "item" => %{
            "$id" => "item.json",
            "$defs" => %{"name" => %{"type" => "string"}},
            "$ref" => "#/$defs/name"
          }
        },
        "properties" => %{
          "a" => %{"$ref" => "item.json"},
          "b" => %{"$ref" => "https://example.com/item.json#/$defs/name"}
        }
      }

      assert_ok(%{"a" => "x", "b" => "y"}, schema, root: schema)
      assert [%{path: "a"}] = assert_error(%{"a" => 1}, schema, root: schema)
      assert [%{path: "b"}] = assert_error(%{"b" => 1}, schema, root: schema)
    end

    test "plain-name anchors and percent-encoded pointers" do
      schema = %{
        "$defs" => %{
          "n" => %{"$anchor" => "number", "type" => "number"},
          "a%b" => %{"type" => "string"}
        },
        "properties" => %{
          "n" => %{"$ref" => "#number"},
          "s" => %{"$ref" => "#/$defs/a%25b"}
        }
      }

      assert_ok(%{"n" => 1, "s" => "x"}, schema, root: schema)
      assert_error(%{"n" => "x"}, schema, root: schema)
      assert_error(%{"s" => 1}, schema, root: schema)
    end

    test "resources are found inside arrays, and never inside data keywords" do
      schema = %{
        "$id" => "https://example.com/root.json",
        "$defs" => %{
          "list" => %{"anyOf" => [%{"$id" => "list.json", "type" => "array"}]},
          "data" => %{"const" => %{"$id" => "data.json", "type" => "string"}}
        },
        "properties" => %{"a" => %{"$ref" => "list.json"}, "b" => %{"$ref" => "data.json"}}
      }

      assert_ok(%{"a" => []}, schema, root: schema)
      assert [%{code: "invalid_reference"}] = assert_error(%{"b" => "x"}, schema, root: schema)
    end

    test "a pointer into an embedded resource resolves later refs against its base" do
      schema = %{
        "$id" => "https://example.com/root.json",
        "$defs" => %{
          "inner" => %{
            "$id" => "nested/inner.json",
            "$defs" => %{"x" => %{"$ref" => "leaf.json"}}
          },
          "leaf" => %{"$id" => "nested/leaf.json", "type" => "integer"}
        },
        "$ref" => "#/$defs/inner/$defs/x"
      }

      assert_ok(1, schema, root: schema)
      assert_error("x", schema, root: schema)
    end

    test "a relative base URI joins nothing: references keep their own spelling" do
      schema = %{
        "$defs" => %{"item" => %{"$id" => "item.json", "$ref" => "other.json"}},
        "$ref" => "item.json"
      }

      registry = %{"other.json" => %{"type" => "string"}}
      assert_ok("x", schema, root: schema, registry: registry)
      assert_error(1, schema, root: schema, registry: registry)
    end

    test "$dynamicRef to a target without a dynamic anchor acts like $ref" do
      schema = %{
        "$defs" => %{"s" => %{"type" => "string"}},
        "$dynamicRef" => "#/$defs/s"
      }

      assert_ok("x", schema, root: schema)
      assert_error(1, schema, root: schema)

      anchored = %{
        "$defs" => %{"s" => %{"$anchor" => "s", "type" => "string"}},
        "$dynamicRef" => "#s"
      }

      assert_ok("x", anchored, root: anchored)
      assert_error(1, anchored, root: anchored)
    end

    test "$dynamicRef resolves to the outermost dynamic anchor in scope" do
      tree = %{
        "$id" => "https://example.com/tree",
        "$dynamicAnchor" => "node",
        "type" => "object",
        "properties" => %{
          "data" => true,
          "children" => %{"type" => "array", "items" => %{"$dynamicRef" => "#node"}}
        }
      }

      strict = %{
        "$id" => "https://example.com/strict-tree",
        "$dynamicAnchor" => "node",
        "$ref" => "tree",
        "unevaluatedProperties" => false
      }

      registry = %{"https://example.com/tree" => tree}
      misspelt = %{"children" => [%{"daat" => 1}]}

      assert_ok(%{"children" => [%{"data" => 1}]}, strict, registry: registry, root: strict)
      assert_error(misspelt, strict, registry: registry, root: strict)
      assert_ok(misspelt, tree, registry: registry, root: tree)
    end

    test "$ref with siblings (2020-12: siblings still apply)" do
      schema = %{
        "$ref" => "#/$defs/base",
        "properties" => %{"b" => %{"type" => "integer"}}
      }

      root = %{"$defs" => %{"base" => %{"properties" => %{"a" => %{"type" => "string"}}}}}

      assert_ok(%{"a" => "x", "b" => 1}, schema, root: root)
      # sibling still enforced
      assert [%{path: "b"}] = assert_error(%{"a" => "x", "b" => "no"}, schema, root: root)
      # ref target still enforced
      assert [%{path: "a"}] = assert_error(%{"a" => 5, "b" => 1}, schema, root: root)
    end
  end

  describe "unevaluatedProperties through the v1.0 Component envelope" do
    setup do
      common_types = %{
        "$defs" => %{
          "ComponentCommon" => %{
            "type" => "object",
            "properties" => %{
              "id" => %{"type" => "string"},
              "catalogId" => %{"type" => "string"},
              "accessibility" => %{"type" => "object"}
            },
            "required" => ["id"]
          }
        }
      }

      catalog = %{
        "$defs" => %{
          "anyComponent" => %{
            "oneOf" => [
              %{
                "type" => "object",
                "properties" => %{
                  "component" => %{"const" => "Text"},
                  "text" => %{"type" => "string"}
                },
                "required" => ["component", "text"]
              },
              %{
                "type" => "object",
                "properties" => %{
                  "component" => %{"const" => "Button"},
                  "child" => %{"type" => "string"}
                },
                "required" => ["component", "child"]
              }
            ],
            "discriminator" => %{"propertyName" => "component"}
          }
        }
      }

      component_schema = %{
        "allOf" => [
          %{"$ref" => "common_types.json#/$defs/ComponentCommon"},
          %{"$ref" => "catalog.json#/$defs/anyComponent"},
          %{"properties" => %{"component" => %{"not" => %{"const" => "Surface"}}}}
        ],
        "unevaluatedProperties" => false
      }

      opts = [
        registry: %{"common_types.json" => common_types, "catalog.json" => catalog},
        root: catalog
      ]

      %{opts: opts, component_schema: component_schema}
    end

    test "valid component passes", %{opts: opts, component_schema: schema} do
      assert_ok(%{"id" => "t1", "component" => "Text", "text" => "hi"}, schema, opts)
    end

    test "unknown property is extra_field (no branch evaluated it)", %{
      opts: opts,
      component_schema: schema
    } do
      details =
        assert_error(
          %{"id" => "t1", "component" => "Text", "text" => "hi", "bogus" => 1},
          schema,
          opts
        )

      assert [%{code: "extra_field", message: msg}] = details
      assert msg =~ "Unevaluated properties are not allowed"
      assert msg =~ "'bogus'"
    end

    test "annotations from other oneOf branches do not leak", %{
      opts: opts,
      component_schema: schema
    } do
      # "child" belongs to the Button branch; a Text component using it
      # must still be rejected as unevaluated.
      details =
        assert_error(
          %{"id" => "t1", "component" => "Text", "text" => "hi", "child" => "x"},
          schema,
          opts
        )

      assert Enum.any?(details, &(&1.code == "extra_field"))
    end

    test "missing required inside the matched branch", %{opts: opts, component_schema: schema} do
      details = assert_error(%{"id" => "t1", "component" => "Text"}, schema, opts)
      assert Enum.any?(details, &(&1.code == "missing_field" and &1.path == "text"))
    end

    test "unknown component type surfaces branch errors via discriminator", %{
      opts: opts,
      component_schema: schema
    } do
      details = assert_error(%{"id" => "t1", "component" => "Chart", "text" => "x"}, schema, opts)
      assert Enum.any?(details, &(&1.code == "invalid_value"))

      # And a discriminated branch error for the component value itself:
      assert Enum.any?(details, fn d ->
               String.contains?(d.message, "not valid under any of the given schemas") or
                 String.contains?(d.message, "was expected")
             end)
    end

    test "component named Surface is rejected by the not branch", %{
      opts: opts,
      component_schema: schema
    } do
      details =
        assert_error(%{"id" => "t1", "component" => "Surface", "text" => "x"}, schema, opts)

      assert Enum.any?(details, &(&1.code == "invalid_value"))
    end

    test "ComponentCommon id requirement holds", %{opts: opts, component_schema: schema} do
      details = assert_error(%{"component" => "Text", "text" => "x"}, schema, opts)
      assert Enum.any?(details, &(&1.code == "missing_field" and &1.path == "id"))
    end
  end

  describe "message fidelity for the conformance fuzzy matcher" do
    test "type error contains 'not of type'" do
      {:error, [%{message: m}]} = Schema.validate(123, %{"type" => "string"})
      assert m =~ "not of type"
    end

    test "required error contains 'is a required property'" do
      {:error, [%{message: m}]} = Schema.validate(%{}, %{"required" => ["x"]})
      assert m =~ "is a required property"
    end

    test "additionalProperties error contains 'Additional properties are not allowed'" do
      {:error, [%{message: m}]} =
        Schema.validate(%{"x" => 1}, %{"additionalProperties" => false})

      assert m =~ "Additional properties are not allowed"
    end
  end

  describe "vocabularies of a custom meta-schema" do
    @vocab "https://json-schema.org/draft/2020-12/vocab/"

    defp meta(id, vocabularies),
      do: %{"$id" => id, "$vocabulary" => Map.new(vocabularies, &{@vocab <> &1, true})}

    test "keywords of vocabularies the meta-schema leaves out are ignored" do
      registry = %{
        "https://example.com/meta" => meta("https://example.com/meta", ~w(core applicator))
      }

      schema = %{
        "$schema" => "https://example.com/meta",
        "properties" => %{"bad" => false, "n" => %{"minimum" => 10}}
      }

      assert_ok(%{"n" => 1}, schema, registry: registry)
      assert_error(%{"bad" => 1}, schema, registry: registry)
    end

    test "a referenced resource is evaluated in its own dialect" do
      registry = %{
        "https://example.com/meta" => meta("https://example.com/meta", ~w(core)),
        "https://example.com/loose" => %{
          "$schema" => "https://example.com/meta",
          "type" => "string"
        }
      }

      assert_ok(1, %{"$ref" => "https://example.com/loose"}, registry: registry)
    end

    test "format-assertion makes format assert" do
      registry = %{
        "https://example.com/meta" => meta("https://example.com/meta", ~w(core format-assertion))
      }

      schema = %{"$schema" => "https://example.com/meta", "format" => "date"}
      assert_ok("2026-10-16", schema, registry: registry)
      assert_error("2026-13-01", schema, registry: registry)
    end

    test "an unknown required vocabulary makes the schema unprocessable" do
      registry = %{
        "https://example.com/meta" => %{
          "$vocabulary" => %{"https://example.com/vocab/custom" => true}
        },
        "https://example.com/optional" => %{
          "$vocabulary" => %{
            "https://example.com/vocab/custom" => false,
            (@vocab <> "validation") => true
          }
        }
      }

      assert_raise ArgumentError, ~r/requires vocabularies/, fn ->
        Schema.validate(1, %{"$schema" => "https://example.com/meta"}, registry: registry)
      end

      schema = %{"$schema" => "https://example.com/optional", "type" => "string"}
      assert_error(1, schema, registry: registry)
    end

    test "standard and unresolvable meta-schemas keep every keyword" do
      assert_error(1, %{
        "$schema" => "https://json-schema.org/draft/2020-12/schema",
        "type" => "string"
      })

      assert_error(1, %{"$schema" => "https://example.com/unknown", "type" => "string"})
    end
  end

  describe "ignored annotation keywords" do
    test "format, title, description, default do not assert" do
      assert_ok("not-a-date", %{"type" => "string", "format" => "date-time"})
      assert_ok(1, %{"title" => "x", "description" => "y", "default" => 2})
      assert_ok("v", %{"deprecated" => true, "x-deprecated-reason" => "old"})
    end
  end

  describe "format assertion (formats: :assert, ajv-formats full mode)" do
    defp format_ok(value, format),
      do: assert_ok(value, %{"type" => "string", "format" => format}, formats: :assert)

    defp format_error(value, format) do
      assert [%{code: "type_mismatch", message: message}] =
               assert_error(value, %{"type" => "string", "format" => format}, formats: :assert)

      assert message =~ "is not a '#{format}'"
    end

    test "uri requires an absolute RFC 3986 URI" do
      format_ok("https://example.com/a?b=1#c", "uri")
      format_ok("mailto:ada@example.com", "uri")
      format_ok("urn:isbn:0451450523", "uri")
      format_ok("https://example.com/%20x", "uri")
      format_error("not a uri", "uri")
      format_error("/relative/path", "uri")
      format_error("https://example.com/a b", "uri")
      format_error("https://example.com/%zz", "uri")
    end

    test "date checks the calendar" do
      format_ok("2024-02-29", "date")
      format_error("2023-02-29", "date")
      format_error("1900-02-29", "date")
      format_ok("2000-02-29", "date")
      format_error("2024-13-01", "date")
      format_error("2024-04-31", "date")
      format_error("2024-4-1", "date")
    end

    test "time requires a time zone and accepts leap seconds only at 23:59 UTC" do
      format_ok("12:30:00Z", "time")
      format_ok("12:30:00.123+05:30", "time")
      format_ok("12:30:00-0800", "time")
      format_ok("23:59:60Z", "time")
      format_ok("15:59:60-08:00", "time")
      format_error("12:30:00", "time")
      format_error("12:30:60Z", "time")
      format_error("24:00:00Z", "time")
      format_error("12:30:00+24:00", "time")
    end

    test "date-time joins date and time with T, t or a space" do
      format_ok("2024-01-15T10:30:00Z", "date-time")
      format_ok("2024-01-15t10:30:00z", "date-time")
      format_ok("2024-01-15 10:30:00+01:00", "date-time")
      format_error("2024-01-15T10:30:00", "date-time")
      format_error("2024-01-15", "date-time")
    end

    test "unknown formats and non-strings are accepted; annotate mode never asserts" do
      format_ok("anything", "x-custom")
      assert_ok(42, %{"format" => "uri"}, formats: :assert)
      assert_ok("not a uri", %{"format" => "uri"}, formats: :annotate)
    end
  end

  describe "applicator edge cases" do
    test "a discriminated oneOf rejects a non-object instance without crashing" do
      schema = %{
        "discriminator" => %{"propertyName" => "component"},
        "oneOf" => [
          %{"type" => "object", "properties" => %{"component" => %{"const" => "Text"}}},
          %{"type" => "object", "properties" => %{"component" => %{"const" => "Icon"}}}
        ]
      }

      assert [_ | _] = assert_error(nil, schema)
      assert [_ | _] = assert_error([1], schema)
    end

    test "a passing `if` contributes annotations to unevaluatedProperties" do
      schema = %{
        "if" => %{"properties" => %{"kind" => %{"const" => "a"}}, "required" => ["kind"]},
        "then" => %{"properties" => %{"extra" => %{"type" => "string"}}},
        "unevaluatedProperties" => false
      }

      assert_ok(%{"kind" => "a", "extra" => "x"}, schema)

      assert [%{code: "extra_field"}] =
               assert_error(%{"kind" => "b", "extra" => "x"}, schema)
    end
  end
end

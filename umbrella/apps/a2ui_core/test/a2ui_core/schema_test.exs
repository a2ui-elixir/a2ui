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

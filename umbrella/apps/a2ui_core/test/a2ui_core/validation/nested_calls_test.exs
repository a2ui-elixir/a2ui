defmodule A2UICore.Validation.NestedCallsTest do
  @moduledoc false
  use ExUnit.Case, async: true

  alias A2UICore.{Catalog, Error, Processor}
  alias A2UICore.Error.Detail
  alias A2UICore.Validation.{Config, NestedCalls}

  @string_args %{
    "type" => "object",
    "properties" => %{"value" => %{"type" => "string"}},
    "required" => ["value"]
  }

  defp function(name) do
    %{
      "type" => "object",
      "properties" => %{"@call" => %{"const" => name}, "args" => @string_args},
      "required" => ["@call", "args"],
      "returnType" => "string"
    }
  end

  defp catalog(id, version, functions) do
    Catalog.from_json!(
      %{
        "catalogId" => id,
        "components" => %{
          "Label" => %{
            "type" => "object",
            "properties" => %{
              "component" => %{"const" => "Label"},
              "text" => %{"$ref" => "common_types.json#/$defs/DynamicString"},
              "parts" => %{
                "type" => "array",
                "items" => %{"$ref" => "common_types.json#/$defs/DynamicString"}
              }
            },
            "required" => ["component", "text"]
          }
        },
        "functions" => Map.new(functions, &{&1, function(&1)})
      },
      protocol_version: version
    )
  end

  defp processor(options \\ []) do
    Processor.new(
      [
        catalog("urn:a", "v1.0", ["upper"]),
        catalog("urn:b", "v1.0", ["shout"]),
        catalog("urn:old", "v0.9", [])
      ],
      options
    )
  end

  defp create(id, catalog_id) do
    body =
      if catalog_id,
        do: %{"surfaceId" => id, "catalogId" => catalog_id},
        else: %{"surfaceId" => id}

    %{"version" => "v1.0", "createSurface" => body}
  end

  defp update(id, components),
    do: %{
      "version" => "v1.0",
      "updateComponents" => %{"surfaceId" => id, "components" => components}
    }

  defp label(text, extra \\ %{}),
    do: Map.merge(%{"id" => "root", "component" => "Label", "text" => text}, extra)

  defp call(name, catalog_id, args \\ %{"value" => "x"}) do
    call = %{"@call" => name, "args" => args}
    if catalog_id, do: Map.put(call, "catalogId", catalog_id), else: call
  end

  defp run(processor, surface \\ {"s", "urn:a"}, components) do
    {id, catalog_id} = surface
    Processor.process(processor, [create(id, catalog_id), update(id, components)])
  end

  defp error!(result) do
    assert {:error, %Error{} = error, _processor} = result
    error
  end

  describe "catalog resolution" do
    test "a call naming an unknown catalog fails at once, even without a configuration" do
      error = error!(run(processor(), [label(call("shout", "urn:nope"))]))
      assert %Error{category: :catalog, message: "Catalog not found: urn:nope"} = error
    end

    test "a catalog of another protocol version is not available on the surface" do
      error = error!(run(processor(), [label(call("shout", "urn:old"))]))

      assert error.category == :catalog

      assert error.message ==
               "Catalog 'urn:old' is not available on surface s: its protocol version does " <>
                 "not match the surface (v1.0)."
    end

    test "a call that names no catalog needs a default catalog" do
      component = label(call("upper", nil), %{"catalogId" => "urn:a"})
      error = error!(run(processor(), {"bare", nil}, [component]))

      assert error.message ==
               "Function call 'upper' in component 'root' names no catalogId and surface bare " <>
                 "has no default catalogId."
    end

    test "system calls belong to no catalog; the calls in their arguments are checked" do
      index = %{"@call" => "@index", "args" => %{"offset" => call("shout", "urn:nope")}}
      error = error!(run(processor(), [label(index)]))
      assert error.message == "Catalog not found: urn:nope"
    end

    test "calls in lists are checked" do
      component = label("t", %{"parts" => ["a", call("shout", "urn:nope")]})
      error = error!(run(processor(), [component]))
      assert error.message == "Catalog not found: urn:nope"
    end

    test "calls that resolve pass" do
      component = label(call("shout", "urn:b"), %{"parts" => [call("upper", nil)]})
      assert {:ok, _processor, _effects} = run(processor(), [component])
    end
  end

  describe "arguments" do
    test "a non-string catalogId is reported without a configuration" do
      error = error!(run(processor(), [label(call("shout", 7))]))

      assert %Error{category: :validation, code: "VALIDATION_FAILED"} = error

      assert [%Detail{code: "type_mismatch", path: "components.root.text.catalogId"}] =
               error.details

      assert error.message =~ "has a non-string 'catalogId'"

      strict = processor(validation: Config.strict())
      assert %Error{category: :validation} = error!(run(strict, [label(call("shout", 7))]))
    end

    test "with a configuration a call is validated in the catalog it runs in" do
      strict = processor(validation: Config.strict())

      error = error!(run(strict, [label(call("shout", "urn:b", %{"value" => 1}))]))

      assert error.category == :validation
      assert error.message =~ "Validation failed for function call 'shout' in component 'root'"
      assert Enum.any?(error.details, &String.starts_with?(&1.path, "components.root.text"))

      assert {:ok, _processor, _effects} = run(strict, [label(call("shout", "urn:b"))])
    end

    test "a call in its component's catalog is left to component validation" do
      strict = processor(validation: Config.strict())

      error = error!(run(strict, [label(call("upper", "urn:a", %{"value" => 1}))]))
      assert error.category == :validation
      refute error.message =~ "Validation failed for function call"

      error = error!(run(strict, [label(call("upper", nil, %{"value" => 1}))]))
      assert error.category == :validation
    end
  end

  describe "merge/2" do
    setup do
      detail = fn path -> Detail.new("invalid_value", "bad #{path}", path) end
      first = Error.new(:validation, "VALIDATION_FAILED", "first", details: [detail.("a")])
      {:ok, detail: detail, first: first}
    end

    test "keeps the second message when all its details are new", %{detail: d, first: first} do
      second = Error.new(:validation, "VALIDATION_FAILED", "second", details: [d.("b")])
      merged = NestedCalls.merge(first, second)

      assert merged.message == "first\nsecond"
      assert Enum.map(merged.details, & &1.path) == ["a", "b"]
    end

    test "lists only the new details of a partly repeated error", %{detail: d, first: first} do
      second = Error.new(:validation, "VALIDATION_FAILED", "second", details: [d.("a"), d.("c")])
      merged = NestedCalls.merge(first, second)

      assert merged.message == "first\nValidation failed for component:\nc: bad c"
      assert Enum.map(merged.details, & &1.path) == ["a", "c"]
    end

    test "drops a fully repeated error", %{detail: d, first: first} do
      second = Error.new(:validation, "VALIDATION_FAILED", "second", details: [d.("a")])
      assert NestedCalls.merge(first, second) == first
    end
  end

  test "label/1 writes a protocol version as vX.Y" do
    assert NestedCalls.label("1.0") == "v1.0"
    assert NestedCalls.label("v0.9") == "v0.9"
    assert NestedCalls.label("nonsense") == "nonsense"
  end
end

defmodule A2UICore.Validation.PayloadTest do
  @moduledoc false
  use ExUnit.Case, async: true

  alias A2UICore.Catalog
  alias A2UICore.Catalog.Basic
  alias A2UICore.Error
  alias A2UICore.Validation.Config
  alias A2UICore.Validation.Payload

  setup_all do
    custom =
      Catalog.from_json!(
        %{
          "catalogId" => "urn:test:defaults",
          "functions" => %{
            "pad" => %{
              "type" => "object",
              "properties" => %{
                "call" => %{"const" => "pad"},
                "args" => %{
                  "type" => "object",
                  "properties" => %{
                    "text" => %{"type" => "string"},
                    "width" => %{"type" => "integer", "default" => 4}
                  },
                  "required" => ["text"]
                }
              },
              "required" => ["call"]
            },
            "legacy" => %{
              "parameters" => %{"count" => %{"type" => "integer", "default" => 1}},
              "required" => ["count"]
            }
          }
        },
        protocol_version: "v0.9"
      )

    {:ok, v09: Basic.catalog("v0.9"), v10: Basic.catalog("v1.0"), custom: custom}
  end

  defp failure(result) do
    assert {:error, %Error{category: :validation, details: details} = error} = result
    {error, Enum.map(details, &{&1.code, &1.path})}
  end

  describe "validate_component/3" do
    test "accepts a valid component", %{v09: catalog} do
      component = %{"id" => "t", "component" => "Text", "text" => "hi"}
      assert Payload.validate_component(catalog, component) == :ok
    end

    test "non-objects are rejected", %{v09: catalog} do
      {error, details} = failure(Payload.validate_component(catalog, "text"))

      assert error.message == "Component must be an object"
      assert details == [{"type_mismatch", "components"}]
    end

    test "missing required properties", %{v09: catalog} do
      {error, details} =
        failure(Payload.validate_component(catalog, %{"id" => "t", "component" => "Text"}))

      assert {"missing_field", "components.t.text"} in details
      assert error.message =~ "components.t.text: 'text' is a required property"
    end

    test "unexpected properties", %{v09: catalog} do
      component = %{"id" => "t", "component" => "Text", "text" => "hi", "bogus" => 1}
      {_error, details} = failure(Payload.validate_component(catalog, component))

      assert details == [{"extra_field", "components.t"}]
    end

    test "wrongly typed properties", %{v09: catalog} do
      component = %{"id" => "t", "component" => "Text", "text" => 5}
      {_error, details} = failure(Payload.validate_component(catalog, component))

      assert {"type_mismatch", "components.t.text"} in details
    end

    test "unknown component types", %{v09: catalog} do
      component = %{"id" => "t", "component" => "Nope"}
      {error, details} = failure(Payload.validate_component(catalog, component))

      assert details == [{"unrecognized_component", "components.t.component"}]
      assert error.message == "components.t.component: Unrecognized component type 'Nope'"
    end

    test "unknown component types without an id are reported against None", %{v09: catalog} do
      {_error, details} = failure(Payload.validate_component(catalog, %{"component" => nil}))
      assert details == [{"unrecognized_component", "components.None.component"}]
    end

    test "relaxed configuration tolerates unknown elements", %{v09: catalog} do
      relaxed = Config.relaxed()

      assert Payload.validate_component(catalog, %{"id" => "t", "component" => "Nope"}, relaxed) ==
               :ok

      component = %{"id" => "t", "component" => "Text", "text" => "hi", "bogus" => 1}
      assert Payload.validate_component(catalog, component, relaxed) == :ok
    end

    test "v1.0 component ids must be identifiers", %{v10: catalog} do
      component = %{"id" => "bad id", "component" => "Text", "text" => "hi"}
      {_error, details} = failure(Payload.validate_component(catalog, component))

      assert details == [{"invalid_identifier", "components.bad id.id"}]
    end

    test "nested function calls are validated", %{v10: catalog} do
      call = %{"@call" => "formatNumber", "args" => %{"value" => 1}}
      component = %{"id" => "t", "component" => "Text", "text" => call}
      assert Payload.validate_component(catalog, component) == :ok

      unknown = %{"@call" => "nope", "args" => %{}}
      component = %{"id" => "t", "component" => "Text", "text" => unknown}
      {_error, details} = failure(Payload.validate_component(catalog, component))

      assert {"unrecognized_function", "functions.nope"} in details
    end

    test "reserved directive keys are rejected in v1.0", %{v10: catalog} do
      component = %{"id" => "t", "component" => "Text", "text" => %{"@note" => 1}}
      {_error, details} = failure(Payload.validate_component(catalog, component))

      assert {"INVALID_RESERVED_KEY", "components.t.text"} in details
    end

    test "calls into another catalog only get identifier checks", %{v10: catalog} do
      foreign = %{"@call" => "anything", "catalogId" => "urn:other", "args" => %{"a" => 1}}

      component = %{"id" => "t", "component" => "Text", "text" => foreign}
      {_error, details} = failure(Payload.validate_component(catalog, component))

      refute Enum.any?(details, &match?({"unrecognized_function", _}, &1))
    end
  end

  describe "validate_function/4" do
    test "returns the arguments", %{v09: catalog} do
      assert Payload.validate_function(catalog, "formatNumber", %{"value" => 1}) ==
               {:ok, %{"value" => 1}}
    end

    test "nil arguments are an empty map", %{v09: catalog} do
      {_error, details} = failure(Payload.validate_function(catalog, "formatNumber", nil))
      assert details == [{"missing_field", "functions.formatNumber.value"}]
    end

    test "arguments must be an object", %{v09: catalog} do
      {error, details} = failure(Payload.validate_function(catalog, "formatNumber", 5))

      assert error.message == "Function arguments for 'formatNumber' must be an object/dictionary"
      assert details == [{"type_mismatch", "functions.formatNumber"}]
    end

    test "unknown functions", %{v09: catalog} do
      {error, details} = failure(Payload.validate_function(catalog, "nope", %{}))

      assert error.message == "Unrecognized function 'nope'"
      assert details == [{"unrecognized_function", "functions.nope"}]

      assert Payload.validate_function(catalog, "nope", %{"a" => 1}, Config.relaxed()) ==
               {:ok, %{"a" => 1}}
    end

    test "too many arguments", %{v09: catalog} do
      args = Map.new(1..1_001, &{"a#{&1}", 1})
      {error, details} = failure(Payload.validate_function(catalog, "formatNumber", args))

      assert error.message ==
               "Function call 'formatNumber' exceeds maximum allowed arguments count (1000)"

      assert details == [{"too_many_arguments", "functions.formatNumber"}]
      assert Payload.max_function_call_args() == 1_000
    end

    test "v1.0 names and argument names must be identifiers", %{v10: catalog} do
      {_error, details} = failure(Payload.validate_function(catalog, "bad name", %{}))
      assert details == [{"invalid_identifier", "functions.bad name"}]

      {_error, details} =
        failure(Payload.validate_function(catalog, "formatNumber", %{"bad arg" => 1}))

      assert details == [{"invalid_identifier", "functions.formatNumber.bad arg"}]
    end

    test "@index is a system function from v1.0", %{v09: v09, v10: v10} do
      assert Payload.validate_function(v10, "@index", %{"offset" => 1}) == {:ok, %{"offset" => 1}}

      {_error, details} = failure(Payload.validate_function(v10, "@index", %{"offset" => "x"}))
      assert {"type_mismatch", "functions.@index.offset"} in details

      {_error, details} = failure(Payload.validate_function(v09, "@index", %{}))
      assert details == [{"unrecognized_function", "functions.@index"}]
    end

    test "schema defaults are filled in", %{custom: catalog} do
      assert Payload.validate_function(catalog, "pad", %{"text" => "a"}) ==
               {:ok, %{"text" => "a", "width" => 4}}

      assert Payload.validate_function(catalog, "pad", %{"text" => "a", "width" => 9}) ==
               {:ok, %{"text" => "a", "width" => 9}}
    end

    test "legacy parameter maps are honoured", %{custom: catalog} do
      assert Payload.validate_function(catalog, "legacy", %{"count" => 3}) ==
               {:ok, %{"count" => 3}}

      {_error, details} = failure(Payload.validate_function(catalog, "legacy", %{}))
      assert details == [{"missing_field", "functions.legacy.count"}]
    end

    test "violations carry a path prefixed with the function", %{custom: catalog} do
      {error, details} = failure(Payload.validate_function(catalog, "pad", %{"text" => 5}))

      assert {"type_mismatch", "functions.pad.text"} in details
      assert error.message =~ "functions.pad.text: 5 is not of type 'string'"
    end
  end

  describe "validate_theme/2" do
    test "a catalog without a theme schema accepts any object", %{v10: catalog} do
      assert Payload.validate_theme(catalog, %{"anything" => 1}) == :ok
    end

    test "themes must be objects", %{v09: catalog} do
      {error, details} = failure(Payload.validate_theme(catalog, 3))

      assert error.message == "Theme payload must be an object"
      assert details == [{"type_mismatch", "theme"}]
    end

    test "values are checked against the theme schema", %{v09: catalog} do
      assert Payload.validate_theme(catalog, %{"primaryColor" => "#00AAFF"}) == :ok

      {_error, details} = failure(Payload.validate_theme(catalog, %{"primaryColor" => 5}))
      assert details == [{"type_mismatch", "primaryColor"}]

      {_error, details} = failure(Payload.validate_theme(catalog, %{"primaryColor" => "#fff"}))
      assert details == [{"type_mismatch", "primaryColor"}]
    end
  end
end

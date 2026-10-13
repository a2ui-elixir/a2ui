defmodule A2UICore.Resolution.BinderTest do
  @moduledoc false
  use ExUnit.Case, async: true

  alias A2UICore.Catalog.Basic
  alias A2UICore.Resolution.{Binder, DataContext}
  alias A2UICore.State.{Component, DataModel}

  setup_all do
    {:ok, v09: Basic.catalog("v0.9.1"), v10: Basic.catalog("v1.0")}
  end

  defp context(catalog, data) do
    DataContext.new("/", data_model: DataModel.new(data), catalog: catalog)
  end

  defp bind(catalog, type, props, data \\ %{}, options \\ []) do
    Binder.bind(context(catalog, data), Component.new("c", type, props), catalog, options)
  end

  defp required_check(path_key, call_key, path) do
    %{
      "condition" => %{call_key => "required", "args" => %{"value" => %{path_key => path}}},
      "message" => "needed"
    }
  end

  describe "bind/4 with a catalog schema" do
    test "dynamic properties resolve bindings", %{v09: v09, v10: v10} do
      assert {%{"text" => "Ada", "variant" => "h1"}, []} =
               bind(v09, "Text", %{"text" => %{"path" => "/n"}, "variant" => "h1"}, %{
                 "n" => "Ada"
               })

      assert {%{"text" => "Ada"}, []} =
               bind(v10, "Text", %{"text" => %{"@path" => "/n"}}, %{"n" => "Ada"})
    end

    test "function calls evaluate", %{v09: v09} do
      call = %{"call" => "formatString", "args" => %{"value" => "n=${/n}"}}

      assert {%{"text" => "n=3"}, []} = bind(v09, "Text", %{"text" => call}, %{"n" => 3})
    end

    test "a missing binding resolves to nil and warns", %{v10: v10} do
      assert {%{"text" => nil}, [{:warning, %{code: "MISSING_DATA_BINDING", path: "/missing"}}]} =
               bind(v10, "Text", %{"text" => %{"@path" => "/missing"}})
    end

    test "actions are kept raw", %{v09: v09} do
      action = %{"event" => %{"name" => "go", "context" => %{"a" => %{"path" => "/x"}}}}

      assert {%{"action" => ^action, "child" => "t"}, []} =
               bind(v09, "Button", %{"child" => "t", "action" => action}, %{"x" => 1})
    end

    test "structural properties are kept for the node resolver", %{v09: v09} do
      template = %{"componentId" => "tpl", "path" => "/items"}

      assert {%{"children" => ^template}, []} =
               bind(v09, "List", %{"children" => template}, %{"items" => [1, 2]})

      assert {%{"children" => ["a", "b"]}, []} =
               bind(v09, "Column", %{"children" => ["a", "b"]})
    end

    test "a schema override replaces the catalog's", %{v09: v09} do
      schema = %{"type" => "object", "properties" => %{"text" => %{"type" => "string"}}}
      props = %{"text" => %{"path" => "/a"}}

      assert {^props, []} = bind(v09, "Text", props, %{"a" => 1}, schema: schema)
    end
  end

  describe "checks" do
    test "failing rules set isValid, validationErrors and validationResult", %{v09: v09, v10: v10} do
      check = required_check("path", "call", "/e")

      assert {props, []} =
               bind(
                 v09,
                 "TextField",
                 %{"label" => "L", "value" => %{"path" => "/e"}, "checks" => [check]},
                 %{"e" => ""}
               )

      assert props["isValid"] == false
      assert props["validationErrors"] == ["needed"]
      assert props["validationResult"] == %{"valid" => false, "message" => "needed"}
      assert props["checks"] == [check]
      assert props["value"] == ""

      check = required_check("@path", "@call", "/e")

      assert {props, []} =
               bind(
                 v10,
                 "TextField",
                 %{"label" => "L", "value" => %{"@path" => "/e"}, "checks" => [check]},
                 %{"e" => ""}
               )

      assert props["isValid"] == false
      assert props["validationResult"] == %{"valid" => false, "message" => "needed"}
    end

    test "passing rules are valid", %{v09: v09} do
      check = required_check("path", "call", "/e")

      assert {props, []} =
               bind(v09, "TextField", %{"label" => "L", "value" => "x", "checks" => [check]}, %{
                 "e" => "filled"
               })

      assert props["isValid"] == true
      assert props["validationErrors"] == []
      assert props["validationResult"] == %{"valid" => true}
    end

    test "the first failure is the validationResult, every message is listed", %{v09: v09} do
      first = %{"condition" => false, "message" => "one"}
      second = %{"condition" => false, "message" => "two"}
      third = %{"condition" => true, "message" => "three"}

      assert {props, []} =
               bind(v09, "TextField", %{
                 "label" => "L",
                 "value" => "",
                 "checks" => [first, second, third]
               })

      assert props["validationErrors"] == ["one", "two"]
      assert props["validationResult"] == %{"valid" => false, "message" => "one"}
    end

    test "a rule may resolve to a full validation result", %{v10: v10} do
      call = %{"@call" => "required", "args" => %{"value" => ""}}
      check = %{"condition" => call, "message" => "fallback"}

      assert {props, _effects} =
               bind(v10, "TextField", %{"label" => "L", "value" => "", "checks" => [check]})

      assert %{"valid" => false} = props["validationResult"]
    end

    test "a rule without a message gets a default", %{v09: v09} do
      assert {props, []} =
               bind(v09, "TextField", %{
                 "label" => "L",
                 "value" => "",
                 "checks" => [%{"condition" => false}]
               })

      assert props["validationResult"] == %{"valid" => false, "message" => "Validation failed"}
    end

    test "a non-list checks property is treated as no rules", %{v09: v09} do
      assert {props, []} =
               bind(v09, "TextField", %{"label" => "L", "value" => "", "checks" => "x"})

      assert props["isValid"] == true
    end

    test "an object with a condition is a rule in itself", %{v09: v09} do
      assert {props, []} =
               bind(
                 v09,
                 "TextField",
                 %{
                   "label" => "L",
                   "value" => "",
                   "checks" => [%{"condition" => %{"path" => "/ok"}, "message" => "no"}]
                 },
                 %{"ok" => true}
               )

      assert props["isValid"] == true
    end
  end

  describe "shape inference" do
    test "without a catalog the value's shape decides", %{v09: v09} do
      props = %{
        "x" => %{"path" => "/a"},
        "plain" => "plain",
        "arr" => [%{"path" => "/a"}],
        "nested" => %{"k" => %{"path" => "/a"}},
        "n" => 5
      }

      assert {resolved, []} =
               Binder.bind(context(v09, %{"a" => 1}), Component.new("c", "Mystery", props), nil)

      assert resolved == %{
               "x" => 1,
               "plain" => "plain",
               "arr" => [1],
               "nested" => %{"k" => 1},
               "n" => 5
             }
    end

    test "v1.0 inference uses @path and @call", %{v10: v10} do
      props = %{
        "x" => %{"@path" => "/a"},
        "old" => %{"path" => "/a"},
        "act" => %{"event" => %{"name" => "n"}},
        "tpl" => %{"componentId" => "t", "path" => "/a"}
      }

      assert {resolved, []} =
               Binder.bind(context(v10, %{"a" => 1}), Component.new("c", "Mystery", props), nil)

      assert resolved["x"] == 1
      assert resolved["old"] == %{"path" => "/a"}
      assert resolved["act"] == %{"event" => %{"name" => "n"}}
      assert resolved["tpl"] == %{"componentId" => "t", "path" => "/a"}
    end

    test "a checks property is a rule list even in an unknown component", %{v09: v09} do
      props = %{"checks" => [%{"condition" => false, "message" => "no"}]}

      assert {resolved, []} =
               Binder.bind(context(v09, %{}), Component.new("c", "Mystery", props), nil)

      assert resolved["isValid"] == false
      assert resolved["validationErrors"] == ["no"]
    end

    test "a component the catalog does not know falls back to inference", %{v09: v09} do
      assert {%{"x" => 1}, []} = bind(v09, "Unknown", %{"x" => %{"path" => "/a"}}, %{"a" => 1})
    end

    test "nil values stay nil", %{v09: v09} do
      assert {%{"text" => nil}, []} = bind(v09, "Text", %{"text" => nil})
    end
  end

  describe "classify/2" do
    test "recognises the common definitions" do
      assert Binder.classify(%{"$ref" => "common_types.json#/$defs/DynamicString"}, %{}) ==
               :dynamic

      assert Binder.classify(%{"$ref" => "common_types.json#/$defs/DataBinding"}, %{}) == :dynamic
      assert Binder.classify(%{"$ref" => "common_types.json#/$defs/Action"}, %{}) == :action

      assert Binder.classify(%{"$ref" => "common_types.json#/$defs/ChildList"}, %{}) ==
               :structural

      assert Binder.classify(%{"$ref" => "common_types.json#/$defs/Checkable"}, %{}) == :checkable
    end

    test "local references resolve against the given definitions" do
      defs = %{
        "Mine" => %{
          "oneOf" => [
            %{"$ref" => "common_types.json#/$defs/DataBinding"},
            %{"allOf" => [%{"$ref" => "common_types.json#/$defs/FunctionCall"}]}
          ]
        },
        "Plain" => %{"type" => "string"}
      }

      assert Binder.classify(%{"$ref" => "#/$defs/Mine"}, defs) == :dynamic
      assert Binder.classify(%{"$ref" => "#/$defs/Plain"}, defs) == :static
    end

    test "unions are dynamic when any branch is" do
      schema = %{
        "oneOf" => [%{"type" => "string"}, %{"$ref" => "common_types.json#/$defs/DynamicBoolean"}]
      }

      assert Binder.classify(schema, %{}) == :dynamic
    end

    test "objects and arrays recurse" do
      array = %{
        "type" => "array",
        "items" => %{"$ref" => "common_types.json#/$defs/DynamicString"}
      }

      assert Binder.classify(array, %{}) == {:array, :dynamic}

      object = %{
        "type" => "object",
        "properties" => %{
          "a" => %{"$ref" => "common_types.json#/$defs/DynamicString"},
          "b" => %{"type" => "string"}
        }
      }

      assert Binder.classify(object, %{}) == {:object, %{"a" => :dynamic, "b" => :static}}
    end

    test "template objects are structural, rule objects checkable" do
      template = %{"properties" => %{"componentId" => %{}, "path" => %{}}}
      assert Binder.classify(template, %{}) == :structural

      rule = %{"type" => "object", "properties" => %{"condition" => %{}, "message" => %{}}}
      assert Binder.classify(rule, %{}) == :checkable

      assert Binder.classify(
               %{"type" => "array", "items" => %{"$ref" => "x#/$defs/CheckRule"}},
               %{}
             ) ==
               :checkable
    end

    test "anything else is static" do
      assert Binder.classify(%{"type" => "string"}, %{}) == :static
      assert Binder.classify(nil, %{}) == :static
      assert Binder.classify(%{"$ref" => "#/$defs/Missing"}, %{}) == :static
    end
  end
end

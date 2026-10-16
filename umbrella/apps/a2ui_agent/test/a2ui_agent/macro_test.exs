defmodule A2UIAgent.MacroTest do
  use ExUnit.Case, async: true

  import A2UIAgent.Builder.Basic

  alias A2UIAgent.Builder
  alias A2UIAgent.Builder.Component
  alias A2UIAgent.Macro

  doctest A2UIAgent.Macro

  defp echo(parameters),
    do: Macro.new("Echo", parameters, fn args -> text(text: inspect(args)) end)

  describe "new/4" do
    test "parameters with types and options" do
      macro =
        Macro.new(
          "Card",
          [
            title: :string,
            subtitle: [type: :string, description: "Below the title.", default: ""],
            note: [type: :string, required: false],
            is_active: :boolean
          ],
          fn _ -> nil end,
          description: "A card."
        )

      assert macro.description == "A card."

      assert [
               %{name: :title, type: :string, required: true, description: "Title"},
               %{name: :subtitle, required: false, default: "", description: "Below the title."},
               %{name: :note, required: false, default: nil},
               %{name: :is_active, description: "Is active"}
             ] = macro.parameters
    end

    test "a list of components is a component list" do
      assert [%{type: :component_list}, %{type: {:list, {:list, :check_rule}}}] =
               echo(items: {:list, :component}, rules: {:list, {:list, :check_rule}}).parameters
    end

    test "unknown types and malformed parameters raise" do
      assert_raise ArgumentError, ~r/unknown macro parameter type/, fn -> echo(x: :date) end
      assert_raise ArgumentError, ~r/unknown macro parameter type/, fn -> echo(x: {:enum, []}) end
      assert_raise ArgumentError, ~r/name: type/, fn -> echo([{"x", :string}]) end
    end
  end

  describe "to_json_schema/2" do
    test "maps each type to its schema" do
      macro =
        Macro.new(
          "All",
          [
            s: :string,
            i: :integer,
            n: :number,
            b: :boolean,
            o: :object,
            a: :any,
            e: {:enum, ["x", "y"]},
            en: {:enum, [1, 2.5]},
            em: {:enum, ["x", 1]},
            l: {:list, :string},
            c: :component,
            cl: :component_list,
            act: :action,
            ds: :dynamic_string,
            dn: :dynamic_number,
            db: :dynamic_boolean,
            dsl: :dynamic_string_list,
            dv: :dynamic_value,
            bind: :data_binding,
            fc: :function_call,
            rules: {:list, :check_rule},
            acc: :accessibility,
            cs: {:list, {:list, :component}}
          ],
          fn _ -> nil end
        )

      properties = Macro.to_json_schema(macro, "#/$defs/")["properties"]

      without =
        Map.new(properties, fn {name, schema} -> {name, Map.delete(schema, "description")} end)

      assert without == %{
               "s" => %{"type" => "string"},
               "i" => %{"type" => "integer"},
               "n" => %{"type" => "number"},
               "b" => %{"type" => "boolean"},
               "o" => %{"type" => "object"},
               "a" => %{},
               "e" => %{"type" => "string", "enum" => ["x", "y"]},
               "en" => %{"type" => "number", "enum" => [1, 2.5]},
               "em" => %{"enum" => ["x", 1]},
               "l" => %{"type" => "array", "items" => %{"type" => "string"}},
               "c" => %{"$ref" => "#/$defs/ComponentId"},
               "cl" => %{"$ref" => "#/$defs/ChildList"},
               "act" => %{"$ref" => "#/$defs/Action"},
               "ds" => %{"$ref" => "#/$defs/DynamicString"},
               "dn" => %{"$ref" => "#/$defs/DynamicNumber"},
               "db" => %{"$ref" => "#/$defs/DynamicBoolean"},
               "dsl" => %{"$ref" => "#/$defs/DynamicStringList"},
               "dv" => %{"$ref" => "#/$defs/DynamicValue"},
               "bind" => %{"$ref" => "#/$defs/DataBinding"},
               "fc" => %{"$ref" => "#/$defs/FunctionCall"},
               "rules" => %{"type" => "array", "items" => %{"$ref" => "#/$defs/CheckRule"}},
               "acc" => %{"$ref" => "#/$defs/AccessibilityAttributes"},
               "cs" => %{
                 "type" => "array",
                 "items" => %{
                   "$ref" => "#/$defs/ChildList"
                 }
               }
             }

      assert properties["c"]["description"] == "C"
      assert properties["s"]["description"] == "S"
    end

    test "required names only required parameters, and the description is optional" do
      schema = Macro.to_json_schema(echo(x: [type: :string, default: "a"]))
      refute Map.has_key?(schema, "required")
      refute Map.has_key?(schema, "description")
    end

    test "the ordered schema keeps the parameters' order" do
      macro = echo(z: :string, a: :string)
      ordered = Macro.ordered_json_schema(macro)

      assert ordered
             |> A2UICore.KeyOrder.get("properties")
             |> Map.get(:values)
             |> Enum.map(&elem(&1, 0)) == ["z", "a"]
    end
  end

  describe "build/2" do
    test "runs the function with the arguments by name" do
      macro =
        Macro.new("Hello", [name: :string], fn %{name: name} -> text(text: "Hi #{name}") end)

      assert %Component{props: [{"text", "Hi Ada"}]} = Macro.build(macro, %{"name" => "Ada"})
      assert %Component{props: [{"text", "Hi Bo"}]} = Macro.build(macro, name: "Bo")
    end

    test "coerces arguments as their types say" do
      capture =
        Macro.new(
          "Capture",
          [
            slot: :component,
            slots: :component_list,
            act: :action,
            value: :dynamic_string,
            acc: :accessibility
          ],
          fn args -> text(id: "t", text: args) end
        )

      %Component{props: [{"text", args}]} =
        Macro.build(capture, %{
          "slot" => "child",
          "slots" => ["a", text(text: "b")],
          "act" => "save",
          "value" => %{"path" => "/v"},
          "acc" => %{"label" => "L"}
        })

      assert args.slot == Builder.ref("child")
      assert [%Builder.Ref{id: "a"}, %Component{}] = args.slots
      assert args.act == Builder.event("save")
      assert args.value == Builder.bind("/v")
      assert args.acc == %{"label" => "L"}
    end

    test "the spellings of an action" do
      assert Macro.coerce(:action, %{"event" => "go"}) == Builder.event("go")

      assert Macro.coerce(:action, %{"event" => %{"name" => "go"}}) == %{
               "event" => %{"name" => "go"}
             }

      assert Macro.coerce(:action, %{"functionCall" => %{"call" => "f"}}) == %{
               "functionCall" => %{"call" => "f"}
             }

      assert Macro.coerce(:action, %{"function_call" => %{"call" => "f"}}) == %{
               "functionCall" => %{"call" => "f"}
             }

      assert Macro.coerce(:action, %{"name" => "go", "context" => %{}}) == %{
               "event" => %{"name" => "go", "context" => %{}}
             }

      assert Macro.coerce(:action, 1) == 1
    end

    test "bindings are recognized in either version's spelling" do
      assert Macro.coerce(:any, %{"@path" => "/a"}) == Builder.bind("/a")
      assert Macro.coerce(:any, %{"path" => 1}) == %{"path" => 1}
      assert Macro.coerce(:any, %{"path" => "/a", "x" => 1}) == %{"path" => "/a", "x" => 1}
    end

    test "optional parameters get their defaults" do
      macro =
        Macro.new(
          "Opt",
          [a: [type: :string, default: "x"], b: [type: :string, required: false]],
          fn args ->
            text(text: inspect(args))
          end
        )

      assert %Component{props: [{"text", text}]} = Macro.build(macro, %{})
      assert text == inspect(%{a: "x", b: nil})
    end

    test "unknown and missing arguments raise" do
      macro = echo(a: :string)

      assert_raise ArgumentError, ~r/has no parameter b/, fn ->
        Macro.build(macro, %{"a" => "x", "b" => 1})
      end

      assert_raise ArgumentError, ~r/missing the argument a/, fn -> Macro.build(macro, %{}) end
    end

    test "the function must return a tree" do
      assert [%Component{}, %Builder.Ref{}, %Macro.Call{}] =
               Macro.build(
                 Macro.new("L", [], fn _ ->
                   [text(text: "a"), Builder.ref("r"), Macro.call("X")]
                 end),
                 %{}
               )

      assert_raise ArgumentError, ~r/must return a component tree/, fn ->
        Macro.build(Macro.new("Bad", [], fn _ -> "text" end), %{})
      end
    end
  end

  test "call/2 makes a call node" do
    macro = echo([])
    assert Macro.call(macro) == %Macro.Call{macro: macro, args: %{}}
    assert Macro.call("Echo", a: 1) == %Macro.Call{macro: "Echo", args: [a: 1]}
  end
end

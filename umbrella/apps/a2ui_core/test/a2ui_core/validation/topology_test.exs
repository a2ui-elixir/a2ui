defmodule A2UICore.Validation.TopologyTest do
  @moduledoc false
  use ExUnit.Case, async: true

  alias A2UICore.Catalog.RefSpec
  alias A2UICore.Error
  alias A2UICore.State.{Component, Components}
  alias A2UICore.Validation.{Config, Topology}

  @infos %{
    "Row" => %{ref_spec: RefSpec.new(list: ["children"])},
    "Column" => %{ref_spec: RefSpec.new(list: ["children"])},
    "Card" => %{ref_spec: RefSpec.new(single: ["child"])},
    "Tabs" => %{ref_spec: RefSpec.new(list: ["tabs"], nested: %{"tabs" => ["child"]})},
    "Text" => %{ref_spec: RefSpec.new()},
    "ListItem" => %{ref_spec: RefSpec.new(), allowed_parents: ["Row"]},
    "Tight" => %{ref_spec: RefSpec.new(list: ["children"]), allowed_children: ["Text"]}
  }

  defp info(%Component{type: type}), do: Map.get(@infos, type)

  # `{id, type, props}` triples.
  defp graph(specs) do
    specs
    |> Enum.map(fn {id, type, props} -> Component.new(id, type, props) end)
    |> Components.from_list()
  end

  defp validate(specs, config \\ Config.strict()),
    do: Topology.validate(graph(specs), &info/1, config)

  defp error!(result) do
    assert {:error, %Error{} = error} = result
    error
  end

  defp chain(count) do
    for index <- 0..(count - 1) do
      id = if index == 0, do: "root", else: "n#{index}"
      props = if index < count - 1, do: %{"child" => "n#{index + 1}"}, else: %{}
      {id, if(index < count - 1, do: "Card", else: "Text"), props}
    end
  end

  describe "validate/3" do
    test "an empty set is valid" do
      assert :ok = Topology.validate(Components.new(), &info/1, Config.strict())
    end

    test "a well-formed tree is valid" do
      specs = [
        {"root", "Column", %{"children" => ["card", "tabs"]}},
        {"card", "Card", %{"child" => "t1"}},
        {"tabs", "Tabs", %{"tabs" => [%{"title" => "a", "child" => "t2"}]}},
        {"t1", "Text", %{}},
        {"t2", "Text", %{}}
      ]

      assert :ok = validate(specs)
    end

    test "a shared child referenced twice is not a cycle" do
      specs = [
        {"root", "Row", %{"children" => ["a", "b"]}},
        {"a", "Card", %{"child" => "leaf"}},
        {"b", "Card", %{"child" => "leaf"}},
        {"leaf", "Text", %{}}
      ]

      assert :ok = validate(specs)
    end

    test "unknown component types contribute no references" do
      assert :ok = validate([{"root", "Mystery", %{"child" => "ghost"}}])
    end
  end

  describe "integrity" do
    test "missing root" do
      error = error!(validate([{"a", "Text", %{}}]))

      assert error.category == :integrity
      assert error.message =~ "Missing root component"
      assert error.message =~ "id='root'"
    end

    test "a custom root id is honoured" do
      assert :ok = validate([{"main", "Text", %{}}], Config.new(root_id: "main"))
    end

    test "a missing root is allowed when configured" do
      assert :ok = validate([{"a", "Text", %{}}], Config.new(allow_missing_root: true))
    end

    test "dangling reference names the component, target and field" do
      specs = [{"root", "Row", %{"children" => ["a", "missing_id"]}}, {"a", "Text", %{}}]
      error = error!(validate(specs))

      assert error.category == :integrity
      assert error.message =~ "references non-existent component 'missing_id'"
      assert error.message =~ "in field 'children[1]'"
      assert error.message =~ "Dangling reference 'missing_id' in component 'root'"
      assert error.path == "components.root"
    end

    test "dangling references are tolerated when allowed" do
      specs = [{"root", "Card", %{"child" => "missing_id"}}]
      assert :ok = validate(specs, Config.new(allow_dangling_references: true))
    end

    test "the first dangling reference in sorted id order is reported" do
      specs = [
        {"root", "Row", %{"children" => ["b", "a"]}},
        {"b", "Card", %{"child" => "gone_b"}},
        {"a", "Card", %{"child" => "gone_a"}}
      ]

      assert error!(validate(specs)).message =~ "non-existent component 'gone_a'"
    end

    test "errors carry a detail with the same code, message and path" do
      error = error!(validate([{"a", "Text", %{}}]))

      assert [%Error.Detail{code: code, message: message}] = error.details
      assert code == error.code
      assert message == error.message
    end
  end

  describe "recursion" do
    test "self-reference" do
      error = error!(validate([{"root", "Card", %{"child" => "root"}}]))

      assert error.category == :recursion
      assert error.message =~ "Self-reference detected"
      assert error.message =~ "Component 'root' references itself in field 'child'"
    end

    test "cycle through two components" do
      specs = [
        {"root", "Card", %{"child" => "a"}},
        {"a", "Card", %{"child" => "b"}},
        {"b", "Card", %{"child" => "a"}}
      ]

      error = error!(validate(specs))
      assert error.category == :recursion
      assert error.message =~ "Circular reference detected"
    end

    test "an orphaned cycle is only found when every component is a traversal start" do
      specs = [
        {"root", "Text", %{}},
        {"a", "Card", %{"child" => "b"}},
        {"b", "Card", %{"child" => "a"}}
      ]

      # Walking from the root never reaches the cycle...
      assert :ok = validate(specs, Config.new(allow_orphan_components: true))

      # ...but with no root required, every component is visited.
      error = error!(validate(specs, Config.new(allow_missing_root: true)))
      assert error.category == :recursion
    end

    test "depth limit is 50 levels below the root by default" do
      assert :ok = validate(chain(51))

      error = error!(validate(chain(52)))
      assert error.category == :recursion
      assert error.message =~ "Global recursion limit exceeded"
      assert error.message =~ "depth > 50"
    end

    test "max_depth overrides the global limit" do
      assert :ok = validate(chain(4), Config.new(max_depth: 3))

      error = error!(validate(chain(5), Config.new(max_depth: 3)))
      assert error.message =~ "Global recursion limit exceeded"
    end
  end

  describe "orphans" do
    test "an unreachable component is an integrity error" do
      specs = [{"root", "Text", %{}}, {"orphan_id", "Text", %{}}]
      error = error!(validate(specs))

      assert error.category == :integrity
      assert error.message =~ "'orphan_id' is not reachable from 'root'"
      assert error.message =~ "Orphaned component 'orphan_id' is not reachable from root"
    end

    test "orphans are tolerated when allowed" do
      specs = [{"root", "Text", %{}}, {"orphan_id", "Text", %{}}]
      assert :ok = validate(specs, Config.new(allow_orphan_components: true))
    end

    test "analyze returns the reachable set" do
      specs = [
        {"root", "Card", %{"child" => "a"}},
        {"a", "Text", %{}},
        {"lost", "Text", %{}}
      ]

      config = Config.new(allow_orphan_components: true)
      assert {:ok, reachable} = Topology.analyze(graph(specs), &info/1, config)
      assert MapSet.equal?(reachable, MapSet.new(["root", "a"]))
    end

    test "with no root every component is a traversal start" do
      specs = [{"a", "Text", %{}}, {"b", "Text", %{}}]
      config = Config.new(allow_missing_root: true)

      assert {:ok, reachable} = Topology.analyze(graph(specs), &info/1, config)
      assert MapSet.equal?(reachable, MapSet.new(["a", "b"]))
    end
  end

  describe "validate_composition/2" do
    test "components without constraints pass" do
      specs = [{"root", "Card", %{"child" => "t"}}, {"t", "Text", %{}}]
      assert :ok = Topology.validate_composition(graph(specs), &info/1)
    end

    test "allowed parent" do
      specs = [{"root", "Row", %{"children" => ["item"]}}, {"item", "ListItem", %{}}]
      assert :ok = Topology.validate_composition(graph(specs), &info/1)
    end

    test "unallowed parent" do
      specs = [{"root", "Card", %{"child" => "item"}}, {"item", "ListItem", %{}}]
      assert {:error, error} = Topology.validate_composition(graph(specs), &info/1)

      assert error.category == :validation
      assert error.code == "UNALLOWED_PARENT"
      assert error.path == "components.item"
      assert error.message =~ "Component 'item' (ListItem) cannot be placed under parent"
      assert error.message =~ "'root' (Card)"
      assert error.message =~ "Allowed parents: ['Row']."
    end

    test "a constrained component nobody references sits under the surface" do
      assert {:error, error} =
               Topology.validate_composition(graph([{"item", "ListItem", %{}}]), &info/1)

      assert error.code == "UNALLOWED_PARENT"
      assert error.message =~ "'Surface' (Surface)"
    end

    test "unallowed child" do
      specs = [{"root", "Tight", %{"children" => ["card"]}}, {"card", "Card", %{}}]
      assert {:error, error} = Topology.validate_composition(graph(specs), &info/1)

      assert error.category == :validation
      assert error.code == "UNALLOWED_CHILD"
      assert error.path == "components.root"
      assert error.message =~ "cannot contain child 'card' (Card)"
      assert error.message =~ "Allowed children: ['Text']."
    end

    test "allowed child" do
      specs = [{"root", "Tight", %{"children" => ["t"]}}, {"t", "Text", %{}}]
      assert :ok = Topology.validate_composition(graph(specs), &info/1)
    end

    test "a dangling child is skipped (integrity reports it)" do
      specs = [{"root", "Tight", %{"children" => ["gone"]}}]
      assert :ok = Topology.validate_composition(graph(specs), &info/1)
    end

    test "empty allowed lists mean unconstrained" do
      info_fun = fn _ -> %{ref_spec: RefSpec.new(), allowed_parents: [], allowed_children: []} end
      assert :ok = Topology.validate_composition(graph([{"a", "X", %{}}]), info_fun)
    end
  end
end

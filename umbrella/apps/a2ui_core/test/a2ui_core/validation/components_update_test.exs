defmodule A2UICore.Validation.ComponentsUpdateTest do
  @moduledoc false
  use ExUnit.Case, async: true

  alias A2UICore.Catalog
  alias A2UICore.Catalog.Basic
  alias A2UICore.Error
  alias A2UICore.State.{Component, Components}
  alias A2UICore.Validation.{ComponentsUpdate, Config}

  setup_all do
    composed =
      Catalog.from_json!(
        %{
          "catalogId" => "urn:test:composed",
          "components" => %{
            "Text" => component("Text", %{"text" => %{"type" => "string"}}, ["text"]),
            "Box" =>
              "Box"
              |> component(
                %{"children" => %{"type" => "array", "items" => %{"type" => "string"}}},
                []
              )
              |> Map.put("allowedChildren", ["Text"]),
            "Leaf" =>
              "Leaf"
              |> component(%{}, [])
              |> Map.put("allowedParents", ["Box"])
          }
        },
        protocol_version: "v0.9"
      )

    {:ok, basic: Basic.catalog("v0.9.1"), composed: composed}
  end

  defp component(name, properties, required) do
    %{
      "type" => "object",
      "properties" =>
        Map.merge(%{"id" => %{"type" => "string"}, "component" => %{"const" => name}}, properties),
      "required" => ["id", "component" | required]
    }
  end

  defp node(id, type, props \\ %{}), do: Component.new(id, type, props)

  defp validate(existing, incoming, catalog, config \\ Config.strict()) do
    ComponentsUpdate.validate(
      Components.from_list(existing),
      incoming,
      fn _component -> catalog end,
      config
    )
  end

  defp codes(%Error{details: details}), do: Enum.map(details, & &1.code)

  defp failure(result) do
    assert {:error, %Error{} = error} = result
    error
  end

  describe "validate/4" do
    test "accepts a consistent batch", %{basic: basic} do
      incoming = [
        node("root", "Column", %{"children" => ["a", "b"]}),
        node("a", "Text", %{"text" => "A"}),
        node("b", "Text", %{"text" => "B"})
      ]

      assert validate([], incoming, basic) == :ok
    end

    test "duplicate ids within the batch", %{basic: basic} do
      incoming = [node("a", "Text", %{"text" => "1"}), node("a", "Text", %{"text" => "2"})]
      error = failure(validate([], incoming, basic))

      assert error.category == :integrity
      assert error.message == "Duplicate component ID 'a' in update payload."
      assert [%{code: "duplicate_id", path: "components.a"}] = error.details
    end

    test "component failures are reported together", %{basic: basic} do
      incoming = [
        node("root", "Text", %{"text" => 5}),
        node("other", "Text", %{"text" => 6})
      ]

      error = failure(validate([], incoming, basic))

      assert error.category == :validation
      assert error.message =~ "Validation failed for component 'Text': "
      assert length(error.details) >= 2
    end

    test "a component whose catalog is unknown is not checked", %{basic: basic} do
      incoming = [node("root", "Text", %{"text" => 5})]

      result =
        ComponentsUpdate.validate(
          Components.new(),
          incoming,
          fn _component -> nil end,
          Config.strict()
        )

      assert result == :ok
      assert is_struct(basic, Catalog)
    end

    test "references are checked against the merged graph", %{basic: basic} do
      existing = [
        node("root", "Column", %{"children" => ["a"]}),
        node("a", "Text", %{"text" => "A"})
      ]

      assert validate(existing, [node("a", "Text", %{"text" => "B"})], basic) == :ok

      dangling = [node("root", "Column", %{"children" => ["a", "missing"]})]
      error = failure(validate(existing, dangling, basic))

      assert error.category == :integrity
      assert error.message =~ "Dangling reference"
    end

    test "a missing root is an error unless allowed", %{basic: basic} do
      incoming = [node("a", "Text", %{"text" => "A"})]

      assert failure(validate([], incoming, basic)).message =~ "root"

      assert validate([], incoming, basic, %{
               Config.strict()
               | allow_missing_root: true,
                 allow_orphan_components: true
             }) ==
               :ok
    end

    test "cycles are rejected", %{basic: basic} do
      incoming = [
        node("root", "Column", %{"children" => ["a"]}),
        node("a", "Column", %{"children" => ["root"]})
      ]

      error = failure(validate([], incoming, basic))

      assert error.category in [:integrity, :recursion]
      assert error.message =~ "Circular reference"
    end

    test "orphans are rejected unless allowed", %{basic: basic} do
      incoming = [node("root", "Text", %{"text" => "R"}), node("lost", "Text", %{"text" => "L"})]

      assert failure(validate([], incoming, basic)).message =~ "lost"

      assert validate([], incoming, basic, %{Config.strict() | allow_orphan_components: true}) ==
               :ok
    end

    test "composition constraints apply", %{composed: composed} do
      ok = [
        node("root", "Box", %{"children" => ["t"]}),
        node("t", "Text", %{"text" => "x"})
      ]

      assert validate([], ok, composed) == :ok

      bad_child = [
        node("root", "Box", %{"children" => ["l"]}),
        node("l", "Leaf")
      ]

      assert codes(failure(validate([], bad_child, composed))) == ["UNALLOWED_CHILD"]

      bad_parent = [
        node("root", "Text", %{"text" => "x"}),
        node("l", "Leaf")
      ]

      error =
        failure(
          validate([], bad_parent, composed, %{Config.strict() | allow_orphan_components: true})
        )

      assert codes(error) == ["UNALLOWED_PARENT"]
    end
  end

  describe "info/2" do
    test "is nil without a catalog" do
      assert ComponentsUpdate.info(node("a", "Text"), nil) == nil
    end

    test "carries the ref spec of a known component", %{basic: basic} do
      info = ComponentsUpdate.info(node("a", "Column"), basic)

      assert is_struct(info.ref_spec)
      assert info[:allowed_parents] == nil
      assert info[:allowed_children] == nil
    end

    test "carries the composition constraints", %{composed: composed} do
      assert %{allowed_children: ["Text"]} = ComponentsUpdate.info(node("a", "Box"), composed)
      assert %{allowed_parents: ["Box"]} = ComponentsUpdate.info(node("a", "Leaf"), composed)
    end

    test "an unknown type has no ref spec", %{basic: basic} do
      assert ComponentsUpdate.info(node("a", "Nope"), basic) == %{ref_spec: nil}
    end
  end
end

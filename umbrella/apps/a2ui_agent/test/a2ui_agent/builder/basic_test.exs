defmodule A2UIAgent.Builder.BasicTest do
  use ExUnit.Case, async: true

  alias A2UIAgent.Builder.{Basic, Component}
  alias A2UICore.Catalog

  doctest A2UIAgent.Builder.Basic

  test "the components are those of both basic catalogs" do
    for version <- ["v0.9.1", "v1.0"] do
      assert Basic.components() == Catalog.Basic.catalog(version).component_order
    end
  end

  test "each component has its function" do
    for name <- Basic.components() do
      function = name |> Macro.underscore() |> String.to_atom()
      assert %Component{component: ^name, props: []} = apply(Basic, function, [])

      assert %Component{id: "x", props: [{"weight", 1}]} =
               apply(Basic, function, [[id: "x", weight: 1]])
    end
  end
end

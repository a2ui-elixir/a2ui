defmodule A2UICore.Resolution.NodeResolverTest do
  @moduledoc false
  use ExUnit.Case, async: true

  doctest A2UICore.Resolution.Binding

  alias A2UICore.Catalog
  alias A2UICore.Catalog.Basic
  alias A2UICore.Error
  alias A2UICore.Resolution.{Action, Binding, Node, NodeResolver}
  alias A2UICore.State.{Component, Components, Surface}

  @now ~U[2026-01-02 03:04:05Z]

  defp surface(components, data \\ %{}, catalog \\ Basic.catalog("v0.9.1")) do
    list = Enum.map(components, &Component.from_wire/1)

    "s"
    |> Surface.new(
      catalog_id: catalog.catalog_id,
      catalogs: %{catalog.catalog_id => catalog},
      data_model: data
    )
    |> Surface.put_components(Components.from_list(list))
  end

  defp put_data(surface, path, value) do
    {:ok, surface, _changes} = Surface.set_data(surface, path, value)
    surface
  end

  defp put_component(surface, wire) do
    Surface.put_components(surface, Components.put(surface.components, Component.from_wire(wire)))
  end

  defp remove_component(surface, id) do
    Surface.put_components(surface, Components.remove(surface.components, id))
  end

  defp column(children), do: %{"id" => "root", "component" => "Column", "children" => children}
  defp text(id, value), do: %{"id" => id, "component" => "Text", "text" => value}

  defp ref_at(resolver, position), do: NodeResolver.positions(resolver)[position].ref

  defp tree do
    surface(
      [column(["a", "b"]), text("a", "A"), text("b", %{"path" => "/b"})],
      %{"b" => "B"}
    )
  end

  describe "new/1" do
    test "resolves child references into nodes" do
      {resolver, notifications} = NodeResolver.new(tree())

      assert NodeResolver.count(resolver) == 3
      root = NodeResolver.root(resolver)

      assert %Node{component_id: "root", type: "Column", state: :resolved, data_path: "/"} = root
      assert root.parent == nil
      assert [{:node, a}, {:node, b}] = root.props["children"]
      assert root.children == [a, b]

      assert %Binding{value: "A", path: nil} = NodeResolver.node(resolver, a).props["text"]
      assert %Binding{value: "B", path: "/b"} = NodeResolver.node(resolver, b).props["text"]
      assert NodeResolver.node(resolver, a).parent == root.ref

      created = for {:node_created, ref} <- notifications, do: ref
      assert Enum.sort(created) == Enum.sort([root.ref, a, b])
      assert length(notifications) == 3
    end

    test "positions name where each node sits" do
      {resolver, _notifications} = NodeResolver.new(tree())

      assert resolver |> NodeResolver.positions() |> Map.keys() |> Enum.sort() ==
               ["root", "root/children/0", "root/children/1"]
    end

    test "instance ids are readable and unique among siblings" do
      surface = surface([column(["t", "t"]), text("t", "same")])
      {resolver, _notifications} = NodeResolver.new(surface)

      ids =
        resolver
        |> NodeResolver.root()
        |> Map.fetch!(:children)
        |> Enum.map(&NodeResolver.node(resolver, &1).instance_id)

      assert ids == ["t", "t#2"]
      assert NodeResolver.root(resolver).instance_id == "root"
    end

    test "a surface without its root component has no nodes" do
      surface = surface([text("a", "A")])
      {resolver, notifications} = NodeResolver.new(surface)

      assert NodeResolver.root(resolver) == nil
      assert NodeResolver.positions(resolver) == %{}
      assert NodeResolver.count(resolver) == 0
      assert notifications == []
    end

    test "the surface's own root id is honoured" do
      surface = %Surface{surface([text("start", "S")]) | root_id: "start"}
      {resolver, _notifications} = NodeResolver.new(surface)

      assert NodeResolver.root(resolver).component_id == "start"
    end
  end

  describe "templates" do
    defp people(names) do
      surface(
        [
          %{
            "id" => "root",
            "component" => "Column",
            "children" => %{"componentId" => "person", "path" => "/people"}
          },
          %{"id" => "person", "component" => "Text", "text" => %{"path" => "name"}}
        ],
        %{"people" => Enum.map(names, &%{"name" => &1})}
      )
    end

    test "one node per item, each in its item's data scope" do
      {resolver, _notifications} = NodeResolver.new(people(["Ada", "Lin"]))
      positions = NodeResolver.positions(resolver)

      first = positions["root/children/0"]
      second = positions["root/children/1"]

      assert {first.data_path, second.data_path} == {"/people/0", "/people/1"}
      assert first.instance_id == "person-[/people/0]"
      assert %Binding{value: "Ada", path: "/people/0/name"} = first.props["text"]
      assert %Binding{value: "Lin", path: "/people/1/name"} = second.props["text"]
    end

    test "appending and removing items keeps the survivors" do
      {resolver, _notifications} = NodeResolver.new(people(["Ada", "Lin"]))
      root = ref_at(resolver, "root")
      first = ref_at(resolver, "root/children/0")
      second = ref_at(resolver, "root/children/1")

      grown =
        put_data(people(["Ada", "Lin"]), "/people", [
          %{"name" => "Ada"},
          %{"name" => "Lin"},
          %{"name" => "Grace"}
        ])

      {resolver, notifications} = NodeResolver.update(resolver, grown)

      third = ref_at(resolver, "root/children/2")
      assert {:node_updated, root} in notifications
      assert {:node_created, third} in notifications
      assert length(notifications) == 2
      assert ref_at(resolver, "root/children/0") == first
      assert ref_at(resolver, "root/children/1") == second

      shrunk = put_data(grown, "/people", [%{"name" => "Ada"}])
      {resolver, notifications} = NodeResolver.update(resolver, shrunk)

      assert Enum.sort(notifications) ==
               Enum.sort([
                 {:node_updated, root},
                 {:node_destroyed, second},
                 {:node_destroyed, third}
               ])

      assert NodeResolver.count(resolver) == 2
      assert NodeResolver.node(resolver, second) == nil
    end

    test "an inserted item re-binds the items after it" do
      {resolver, _notifications} = NodeResolver.new(people(["Ada", "Lin"]))
      second = ref_at(resolver, "root/children/1")

      inserted =
        put_data(people(["Ada"]), "/people", [
          %{"name" => "Ada"},
          %{"name" => "New"},
          %{"name" => "Lin"}
        ])

      {resolver, notifications} = NodeResolver.update(resolver, inserted)

      assert {:node_updated, second} in notifications
      assert ref_at(resolver, "root/children/1") == second

      assert %Binding{value: "New"} =
               NodeResolver.positions(resolver)["root/children/1"].props["text"]
    end

    test "a template over something that is not a list has no children" do
      surface = put_data(people(["Ada"]), "/people", "nope")
      {resolver, _notifications} = NodeResolver.new(surface)

      assert NodeResolver.root(resolver).props["children"] == []
      assert NodeResolver.count(resolver) == 1
    end
  end

  describe "update/2" do
    test "reports only the nodes whose props changed, keeping their identity" do
      {resolver, _notifications} = NodeResolver.new(tree())
      b = ref_at(resolver, "root/children/1")

      {updated, notifications} = NodeResolver.update(resolver, put_data(tree(), "/b", "C"))

      assert notifications == [{:node_updated, b}]
      assert %Binding{value: "C"} = NodeResolver.node(updated, b).props["text"]
      assert ref_at(updated, "root") == ref_at(resolver, "root")
    end

    test "writing the same value again is silent" do
      {resolver, _notifications} = NodeResolver.new(tree())

      assert {_resolver, []} = NodeResolver.update(resolver, put_data(tree(), "/b", "B"))
    end

    test "replacing a definition's properties updates every instance once" do
      {resolver, _notifications} = NodeResolver.new(people(["Ada", "Lin"]))
      surface = put_component(people(["Ada", "Lin"]), text("person", "Fixed"))

      {resolver, notifications} = NodeResolver.update(resolver, surface)

      assert length(notifications) == 2
      assert Enum.all?(notifications, &match?({:node_updated, _ref}, &1))

      assert %Binding{value: "Fixed", path: nil} =
               NodeResolver.positions(resolver)["root/children/0"].props["text"]
    end

    test "a pending child is replaced when its definition arrives" do
      pending = surface([%{"id" => "root", "component" => "Card", "child" => "late"}])
      {resolver, _notifications} = NodeResolver.new(pending)
      root = ref_at(resolver, "root")
      placeholder = NodeResolver.positions(resolver)["root/child"]

      assert %Node{state: :pending, component_id: "late", props: %{}, children: []} = placeholder
      assert Node.placeholder?(placeholder)

      {resolver, notifications} =
        NodeResolver.update(resolver, put_component(pending, text("late", "Hi")))

      arrived = NodeResolver.positions(resolver)["root/child"]
      assert arrived.state == :resolved
      refute Node.placeholder?(arrived)
      refute arrived.ref == placeholder.ref
      assert ref_at(resolver, "root") == root

      assert Enum.sort(notifications) ==
               Enum.sort([
                 {:node_created, arrived.ref},
                 {:node_updated, root},
                 {:node_destroyed, placeholder.ref}
               ])
    end

    test "removing a definition turns its node into a pending placeholder" do
      {resolver, _notifications} = NodeResolver.new(tree())
      a = ref_at(resolver, "root/children/0")

      {resolver, notifications} = NodeResolver.update(resolver, remove_component(tree(), "a"))

      assert NodeResolver.positions(resolver)["root/children/0"].state == :pending
      assert {:node_destroyed, a} in notifications
    end

    test "a root that arrives and goes away creates and destroys the tree" do
      empty = surface([])
      {resolver, []} = NodeResolver.new(empty)

      with_root = put_component(empty, text("root", "Hello"))
      {resolver, [{:node_created, ref}]} = NodeResolver.update(resolver, with_root)
      assert NodeResolver.root(resolver).ref == ref

      {resolver, [{:node_destroyed, ^ref}]} = NodeResolver.update(resolver, empty)
      assert NodeResolver.root(resolver) == nil
    end

    test "a component whose type changes is a new node" do
      {resolver, _notifications} = NodeResolver.new(tree())
      old = ref_at(resolver, "root/children/0")

      changed = put_component(tree(), %{"id" => "a", "component" => "Divider"})
      {resolver, notifications} = NodeResolver.update(resolver, changed)

      new = NodeResolver.positions(resolver)["root/children/0"]
      assert new.type == "Divider"
      refute new.ref == old
      assert {:node_destroyed, old} in notifications
      assert {:node_created, new.ref} in notifications
    end

    test "tab content nests child references under their slot" do
      tabs = %{
        "id" => "root",
        "component" => "Tabs",
        "tabs" => [%{"title" => "One", "child" => "p1"}, %{"title" => "Two", "child" => "p2"}]
      }

      {resolver, _notifications} =
        NodeResolver.new(surface([tabs, text("p1", "1"), text("p2", "2")]))

      assert resolver |> NodeResolver.positions() |> Map.keys() |> Enum.sort() ==
               ["root", "root/tabs/0/child", "root/tabs/1/child"]

      assert [%{"title" => %Binding{value: "One"}, "child" => {:node, _ref}} | _rest] =
               NodeResolver.root(resolver).props["tabs"]
    end
  end

  describe "diagnostics" do
    test "an unknown component type is an error placeholder, reported once" do
      surface = surface([column(["m"]), %{"id" => "m", "component" => "Mystery"}])
      {resolver, notifications} = NodeResolver.new(surface)

      assert %Node{state: :unknown_type, type: "Mystery"} =
               NodeResolver.positions(resolver)["root/children/0"]

      assert [{:error, %{code: "UNKNOWN_COMPONENT_TYPE", component_id: "m"}}] =
               Enum.filter(notifications, &match?({:error, _payload}, &1))

      {_resolver, again} = NodeResolver.update(resolver, put_data(surface, "/x", 1))
      assert again == []
    end

    test "a component referenced by its own descendant is cut with a cyclic placeholder" do
      surface =
        surface([
          %{"id" => "root", "component" => "Card", "child" => "other"},
          %{"id" => "other", "component" => "Card", "child" => "root"}
        ])

      {resolver, notifications} = NodeResolver.new(surface)

      assert %Node{state: :cyclic, component_id: "root"} =
               NodeResolver.positions(resolver)["root/child/child"]

      assert NodeResolver.count(resolver) == 3

      assert [{:error, %{code: "CYCLIC_REFERENCE"}}] =
               Enum.filter(notifications, &match?({:error, _p}, &1))
    end

    test "binding problems are reported when they appear, not while they last" do
      surface = surface([text("root", %{"path" => "/missing"})])
      {resolver, notifications} = NodeResolver.new(surface)

      assert [{:warning, %{code: "MISSING_DATA_BINDING", component_id: "root", data_path: "/"}}] =
               Enum.filter(notifications, &match?({:warning, _payload}, &1))

      {resolver, again} = NodeResolver.update(resolver, put_data(surface, "/other", 1))
      assert again == []

      present = put_data(surface, "/missing", "here")
      {resolver, fixed} = NodeResolver.update(resolver, present)
      assert [{:node_updated, _ref}] = fixed

      {_resolver, back} = NodeResolver.update(resolver, put_data(present, "/missing", nil))
      assert Enum.any?(back, &match?({:warning, %{code: "MISSING_DATA_BINDING"}}, &1))
    end
  end

  describe "dispose/1" do
    test "destroys every node and stops the resolver" do
      {resolver, _notifications} = NodeResolver.new(tree())
      refs = for {_path, node} <- NodeResolver.positions(resolver), do: node.ref

      {disposed, notifications} = NodeResolver.dispose(resolver)

      assert Enum.sort(for {:node_destroyed, ref} <- notifications, do: ref) == Enum.sort(refs)
      assert NodeResolver.root(disposed) == nil
      assert NodeResolver.count(disposed) == 0

      assert {^disposed, []} = NodeResolver.dispose(disposed)
      assert {^disposed, []} = NodeResolver.update(disposed, tree())
    end
  end

  describe "write/4" do
    test "a binding to a path yields the absolute path and value" do
      {resolver, _notifications} = NodeResolver.new(people(["Ada"]))
      ref = ref_at(resolver, "root/children/0")

      assert {:ok, "/people/0/name", "Grace"} = NodeResolver.write(resolver, ref, "text", "Grace")
    end

    test "a literal is not writable" do
      {resolver, _notifications} = NodeResolver.new(tree())
      ref = ref_at(resolver, "root/children/0")

      assert {:error, %Error{code: "NOT_WRITABLE"}} =
               NodeResolver.write(resolver, ref, "text", "x")

      assert {:error, %Error{code: "NOT_WRITABLE"}} =
               NodeResolver.write(resolver, ref, "nope", "x")
    end

    test "an unknown node is an error" do
      {resolver, _notifications} = NodeResolver.new(tree())

      assert {:error, %Error{code: "NODE_NOT_FOUND"}} =
               NodeResolver.write(resolver, 999, "text", "x")
    end
  end

  describe "invoke/5" do
    defp button_wire(action) do
      [
        %{"id" => "root", "component" => "Button", "child" => "label", "action" => action},
        text("label", "Go")
      ]
    end

    defp button(action), do: surface(button_wire(action))

    test "an event action reads the data as it is at invocation" do
      action = %{"event" => %{"name" => "save", "context" => %{"name" => %{"path" => "/name"}}}}
      surface = put_data(button(action), "/name", "Ada")
      {resolver, _notifications} = NodeResolver.new(surface)
      root = ref_at(resolver, "root")

      assert %Action{} = NodeResolver.root(resolver).props["action"]

      later = put_data(surface, "/name", "Grace")

      assert {:ok, [{:action_event, event}]} =
               NodeResolver.invoke(resolver, later, root, "action", @now)

      assert %{
               "name" => "save",
               "surfaceId" => "s",
               "sourceComponentId" => "root",
               "context" => %{"name" => "Grace"},
               "timestamp" => "2026-01-02T03:04:05Z"
             } = event
    end

    test "a function-call action runs the catalog function and sends no event" do
      owner = self()

      catalog =
        Catalog.put_implementations(Basic.catalog("v0.9.1"), %{
          "openUrl" => fn args, _context ->
            send(owner, {:called, args})
            {:ok, nil}
          end
        })

      action = %{
        "functionCall" => %{"call" => "openUrl", "args" => %{"url" => "https://example.test"}}
      }

      surface = surface(button_wire(action), %{}, catalog)
      {resolver, _notifications} = NodeResolver.new(surface)

      assert {:ok, []} =
               NodeResolver.invoke(resolver, surface, ref_at(resolver, "root"), "action")

      assert_received {:called, %{"url" => "https://example.test"}}
    end

    test "only actions can be invoked" do
      {resolver, _notifications} = NodeResolver.new(tree())

      assert {:error, %Error{code: "NOT_AN_ACTION"}} =
               NodeResolver.invoke(resolver, tree(), ref_at(resolver, "root/children/0"), "text")

      assert {:error, %Error{code: "NODE_NOT_FOUND"}} =
               NodeResolver.invoke(resolver, tree(), 999, "action")
    end
  end
end

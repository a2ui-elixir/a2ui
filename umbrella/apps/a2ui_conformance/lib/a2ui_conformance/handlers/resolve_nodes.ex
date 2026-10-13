defmodule A2UIConformance.Handlers.ResolveNodes do
  @moduledoc false

  # `resolve_nodes` (`conformance/core/node_resolution.md`). The upstream
  # harness that defines it is the TypeScript runner
  # `typescript/web_core/tests/conformance/node-resolution.ts`; this is a
  # port of it onto the pure resolver.
  #
  # A case loads a fixture (catalog, data, flat components), resolves it,
  # checks the initial expectation, and applies its steps in order. After
  # every step it checks:
  #
  #   * `nodes` — the mounted positions are exactly the expected ones, and
  #     each named field (`component_id`, `type`, `state`, `data_path`,
  #     `props`) matches;
  #   * `emissions` — props updates per position, counted for nodes that
  #     were mounted when the step began and still are;
  #   * `destroyed` — destructions per position, addressed by the
  #     position the node had when the step began;
  #   * `same_nodes` / `replaced_nodes` — identity across the step;
  #   * `data`, `events`, `functions`.
  #
  # Declared catalog functions are recorders that return nothing. The
  # resolver is immutable, so the TS checks that a previously obtained
  # binding snapshot "still holds" and that the last emitted props equal
  # the final props are true by construction and not repeated here.

  @behaviour A2UIConformance.Handler

  import ExUnit.Assertions

  alias A2UIConformance.{Case, Matchers, Registry, Yaml}
  alias A2UICore.Catalog
  alias A2UICore.Resolution.{Action, Binding, NodeResolver}
  alias A2UICore.State.{Component, Components, Surface}

  @impl true
  def run(%Case{raw: raw, name: name}, _context) do
    fixture = load_fixture(raw["fixture"])
    catalog = load_catalog(fixture["catalog"])
    surface = build_surface(fixture, catalog)
    {resolver, _notifications} = NodeResolver.new(surface)

    initial = %{
      surface: surface,
      resolver: resolver,
      before: %{},
      notifications: [],
      events: [],
      destroyed_before: %{}
    }

    check(raw["expect"], initial, drain_calls(), "#{name} initial")

    _final =
      (raw["steps"] || [])
      |> Enum.with_index()
      |> Enum.reduce(initial, fn {step, index}, state ->
        run_step(step, state, "#{name} step #{index} (#{step["op"]})")
      end)

    :ok
  end

  # -- fixture --------------------------------------------------------------------

  defp conformance_root, do: Path.join(Registry.reference_root(), "conformance")

  defp load_fixture(path) do
    {:ok, [fixture]} = Yaml.load_file(Path.join(conformance_root(), path))
    fixture
  end

  defp load_catalog(path) do
    document =
      path
      |> Path.expand(conformance_root())
      |> File.read!()
      |> Jason.decode!()

    catalog = Catalog.from_json!(document, protocol_version: protocol_version(path))
    recorders = Map.new(Map.keys(catalog.functions), &{&1, recorder(&1)})
    Catalog.put_implementations(catalog, recorders)
  end

  defp protocol_version(path) do
    cond do
      String.contains?(path, "v0_9_1") -> "v0.9.1"
      String.contains?(path, "v0_9") -> "v0.9"
      true -> "v1.0"
    end
  end

  # A function implementation that records its call in the test
  # process's mailbox and returns nothing.
  defp recorder(name) do
    owner = self()

    fn args, _context ->
      send(owner, {:recorded_call, %{"name" => name, "args" => args}})
      {:ok, nil}
    end
  end

  defp drain_calls(calls \\ []) do
    receive do
      {:recorded_call, call} -> drain_calls([call | calls])
    after
      0 -> Enum.reverse(calls)
    end
  end

  defp build_surface(fixture, catalog) do
    components =
      Components.from_list(
        Enum.map(fixture["components"] || [], fn %{"id" => id, "component" => type} = wire ->
          Component.new(id, type, Map.drop(wire, ["id", "component"]))
        end)
      )

    "s"
    |> Surface.new(
      catalog_id: catalog.catalog_id,
      catalogs: %{catalog.catalog_id => catalog},
      data_model: fixture["data"] || %{}
    )
    |> Surface.put_components(components)
  end

  # -- steps ----------------------------------------------------------------------

  defp run_step(step, state, reason) do
    positions = NodeResolver.positions(state.resolver)
    before = Map.new(positions, fn {path, node} -> {path, node.ref} end)
    drain_calls()

    {state, notifications, events} = apply_operation(step, state, before, reason)
    functions = drain_calls()

    state = %{
      state
      | before: before,
        notifications: notifications,
        events: events
    }

    destroyed = for {:node_destroyed, ref} <- notifications, do: ref

    assert_not_destroyed_before(destroyed, state.destroyed_before, reason)

    state = %{
      state
      | destroyed_before: Map.merge(state.destroyed_before, Map.new(destroyed, &{&1, true}))
    }

    check(step["expect"], state, functions, reason)
    state
  end

  defp apply_operation(%{"op" => "set_data"} = step, state, _before, _reason) do
    {:ok, surface, _changes} = Surface.set_data(state.surface, step["path"], step["value"])
    update(state, surface)
  end

  defp apply_operation(%{"op" => "update_components"} = step, state, _before, reason) do
    components =
      Enum.reduce(step["components"], state.surface.components, fn wire, components ->
        %{"id" => id, "component" => type} = wire
        props = Map.drop(wire, ["id", "component"])

        case Components.get(components, id) do
          nil ->
            Components.put(components, Component.new(id, type, props))

          %Component{type: ^type} = existing ->
            Components.put(components, %Component{existing | props: props})

          %Component{} ->
            flunk("#{reason}: update_components cannot change #{id}'s type")
        end
      end)

    update(state, Surface.put_components(state.surface, components))
  end

  defp apply_operation(%{"op" => "remove_component"} = step, state, _before, _reason) do
    components = Components.remove(state.surface.components, step["component_id"])
    update(state, Surface.put_components(state.surface, components))
  end

  defp apply_operation(%{"op" => "write"} = step, state, before, reason) do
    ref = required_ref(before, step["node"], reason)

    case NodeResolver.write(state.resolver, ref, step["property"], step["value"]) do
      {:ok, path, value} ->
        {:ok, surface, _changes} = Surface.set_data(state.surface, path, value)
        update(state, surface)

      {:error, _error} ->
        flunk("#{reason}: not a writable binding")
    end
  end

  defp apply_operation(%{"op" => "invoke"} = step, state, before, reason) do
    ref = required_ref(before, step["node"], reason)

    case NodeResolver.invoke(state.resolver, state.surface, ref, step["property"]) do
      {:ok, interactions} ->
        events =
          for {:action_event, event} <- interactions do
            %{
              "name" => event["name"],
              "source_component_id" => event["sourceComponentId"],
              "context" => event["context"]
            }
          end

        {state, [], events}

      {:error, _error} ->
        flunk("#{reason}: not an action")
    end
  end

  defp apply_operation(%{"op" => "dispose"}, state, _before, _reason) do
    {resolver, notifications} = NodeResolver.dispose(state.resolver)
    {%{state | resolver: resolver}, notifications, []}
  end

  defp apply_operation(%{"op" => op}, _state, _before, reason),
    do: flunk("#{reason}: unknown node operation #{inspect(op)}")

  defp update(state, surface) do
    {resolver, notifications} = NodeResolver.update(state.resolver, surface)
    {%{state | surface: surface, resolver: resolver}, notifications, []}
  end

  defp required_ref(before, path, reason) do
    case Map.fetch(before, path) do
      {:ok, ref} -> ref
      :error -> flunk("#{reason}: no node at #{path}")
    end
  end

  defp assert_not_destroyed_before(destroyed, seen, reason) do
    for ref <- destroyed do
      refute Map.has_key?(seen, ref), "#{reason}: node #{ref} was destroyed twice"
    end

    :ok
  end

  # -- assertions -----------------------------------------------------------------

  defp check(%{"nodes" => expected_nodes} = expected, state, functions, reason) do
    positions = NodeResolver.positions(state.resolver)
    paths = Map.new(positions, fn {path, node} -> {node.ref, path} end)

    assert_structure(state.resolver, positions, reason)
    assert_node_paths(positions, expected_nodes, reason)

    for {path, fields} <- expected_nodes do
      assert_node(Map.fetch!(positions, path), path, fields || %{}, paths, reason)
    end

    assert_emissions(expected, state, positions, reason)
    assert_destroyed(expected, state, reason)
    assert_identity(expected, state, positions, reason)
    assert_data(expected, state, reason)

    Matchers.assert_json_equal(expected["events"] || [], state.events, "#{reason}: events")
    Matchers.assert_json_equal(expected["functions"] || [], functions, "#{reason}: functions")
  end

  # Every mounted position holds a distinct node, and siblings have
  # distinct instance ids.
  defp assert_structure(resolver, positions, reason) do
    refs = Enum.map(positions, fn {_path, node} -> node.ref end)
    assert length(refs) == length(Enum.uniq(refs)), "#{reason}: each position needs its own node"

    for {path, node} <- positions do
      ids = Enum.map(node.children, &NodeResolver.node(resolver, &1).instance_id)

      assert length(ids) == length(Enum.uniq(ids)),
             "#{reason}: #{path} has duplicate sibling instance ids"
    end

    :ok
  end

  defp assert_node_paths(positions, expected_nodes, reason) do
    assert Enum.sort(Map.keys(positions)) == Enum.sort(Map.keys(expected_nodes)),
           "#{reason}: node paths"
  end

  defp assert_node(node, path, fields, paths, reason) do
    actual = %{
      "component_id" => node.component_id,
      "type" => node.type,
      "state" => Atom.to_string(node.state),
      "data_path" => node.data_path
    }

    for key <- ~w(component_id type state data_path), Map.has_key?(fields, key) do
      assert actual[key] == fields[key], "#{reason}: #{path}.#{key}"
    end

    for {key, expected} <- fields["props"] || %{} do
      assert Map.has_key?(node.props, key), "#{reason}: #{path}.#{key} is absent"

      Matchers.assert_json_equal(
        expected,
        normalize(Map.fetch!(node.props, key), paths),
        "#{reason}: #{path}.#{key}"
      )
    end

    :ok
  end

  # Props updates of nodes that were mounted when the step began and
  # still are; new and retired nodes are checked through structure,
  # identity and destruction instead.
  defp assert_emissions(expected, state, positions, reason) do
    surviving = Map.new(positions, fn {_path, node} -> {node.ref, true} end)
    before_paths = Map.new(state.before, fn {path, ref} -> {ref, path} end)

    emissions =
      for {:node_updated, ref} <- state.notifications,
          Map.has_key?(surviving, ref),
          path = Map.get(before_paths, ref),
          reduce: %{} do
        counts -> Map.update(counts, path, 1, &(&1 + 1))
      end

    Matchers.assert_json_equal(expected["emissions"] || %{}, emissions, "#{reason}: emissions")
  end

  defp assert_destroyed(expected, state, reason) do
    before_paths = Map.new(state.before, fn {path, ref} -> {ref, path} end)

    destroyed =
      for {:node_destroyed, ref} <- state.notifications, reduce: %{} do
        counts ->
          path = Map.get(before_paths, ref)
          assert path, "#{reason}: node #{ref} was destroyed without having been mounted"
          assert NodeResolver.node(state.resolver, ref) == nil, "#{reason}: #{path} not disposed"
          Map.update(counts, path, 1, &(&1 + 1))
      end

    Matchers.assert_json_equal(expected["destroyed"] || %{}, destroyed, "#{reason}: destroyed")
  end

  defp assert_identity(expected, state, positions, reason) do
    for path <- expected["same_nodes"] || [] do
      assert current_ref(positions, path, reason) == required_ref(state.before, path, reason),
             "#{reason}: #{path} identity"
    end

    for path <- expected["replaced_nodes"] || [] do
      refute current_ref(positions, path, reason) == required_ref(state.before, path, reason),
             "#{reason}: #{path} replacement"
    end

    :ok
  end

  defp current_ref(positions, path, reason) do
    case Map.fetch(positions, path) do
      {:ok, node} -> node.ref
      :error -> flunk("#{reason}: no node at #{path}")
    end
  end

  defp assert_data(expected, state, reason) do
    for {path, value} <- expected["data"] || %{} do
      {:ok, actual} = Surface.get_data(state.surface, path)
      Matchers.assert_json_equal(value, actual, "#{reason}: data #{path}")
    end

    :ok
  end

  # The detached form the suite compares: bindings as `{value, writable}`,
  # child nodes by position, actions as `{action: true}`.
  defp normalize(%Binding{value: value} = binding, paths) do
    %{"value" => normalize(value, paths), "writable" => Binding.writable?(binding)}
  end

  defp normalize(%Action{}, _paths), do: %{"action" => true}
  defp normalize({:node, ref}, paths), do: %{"node" => Map.fetch!(paths, ref)}
  defp normalize(list, paths) when is_list(list), do: Enum.map(list, &normalize(&1, paths))

  defp normalize(map, paths) when is_map(map),
    do: Map.new(map, fn {key, value} -> {key, normalize(value, paths)} end)

  defp normalize(other, _paths), do: other
end

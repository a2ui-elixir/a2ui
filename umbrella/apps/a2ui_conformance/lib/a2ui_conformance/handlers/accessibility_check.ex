defmodule A2UIConformance.Handlers.AccessibilityCheck do
  @moduledoc false

  # `accessibility_check` (`conformance/core/accessibility.yaml`). Upstream
  # leaves this suite to renderers: the Python harness skips it and the
  # TypeScript runner has no handler. The model-level part is what it
  # says about the accessibility tree, which this handler checks against
  # `A2UICore.Accessibility`:
  #
  #   * `label`, `description`, `live`, `hidden`, `role`, `checked` of each
  #     component in `assertions.accessibilityTree` equal the computed
  #     attributes; a `{path: …}` expectation asserts that the attribute
  #     is bound to that data path;
  #   * the catalog named by `catalogPath` passes the catalog lint.
  #
  # `assertions.axeCore` names DOM rules of a browser renderer and has no
  # model-level counterpart; it is ignored.

  @behaviour A2UIConformance.Handler

  import ExUnit.Assertions

  alias A2UIConformance.{Case, Matchers, Registry}
  alias A2UICore.Accessibility
  alias A2UICore.Catalog
  alias A2UICore.Resolution.DataContext
  alias A2UICore.State.{Component, Surface}

  @bound_attributes ~w(label description live hidden)
  @computed_attributes ~w(label description live hidden role checked)

  @impl true
  def run(%Case{raw: raw, protocol_version: version}, _context) do
    catalog = load_catalog(raw["catalogPath"], version)
    assert Accessibility.lint(catalog) == [], "the catalog has unlabellable components"

    surface = build_surface(raw, catalog)
    context = DataContext.for_surface(surface)
    components = components(raw["surface"] || %{})

    tree = get_in(raw, ["assertions", "accessibilityTree"]) || %{}

    for {id, expected} <- tree do
      component = Map.get(components, id) || flunk("component '#{id}' is not in the surface")
      assert_component(component, expected, context)
    end

    :ok
  end

  defp load_catalog(path, version) do
    document =
      Registry.reference_root()
      |> Path.join(path)
      |> File.read!()
      |> Jason.decode!()

    Catalog.from_json!(document, protocol_version: version)
  end

  defp build_surface(raw, catalog) do
    Surface.new(get_in(raw, ["surface", "id"]) || "root",
      catalog_id: catalog.catalog_id,
      catalogs: %{catalog.catalog_id => catalog},
      data_model: raw["dataModel"] || %{}
    )
  end

  # The case's compact surface: the root component's definition sits at
  # the top, next to `id` and `components`.
  defp components(surface) do
    root = Map.drop(surface, ["components"])

    surface
    |> Map.get("components", %{})
    |> Map.put(root["id"] || "root", root)
    |> Map.new(fn {id, %{"component" => type} = definition} ->
      {id, Component.new(id, type, Map.drop(definition, ["id", "component"]))}
    end)
  end

  defp assert_component(%Component{id: id} = component, expected, context) do
    {attributes, _effects} = Accessibility.attributes(component, context)

    for {key, value} <- expected do
      assert_attribute(id, key, value, component, attributes)
    end
  end

  defp assert_attribute(id, key, %{"path" => path}, component, _attributes)
       when key in @bound_attributes do
    declared = get_in(component.props, ["accessibility", key])

    assert is_map(declared) and (declared["@path"] == path or declared["path"] == path),
           "#{id}: #{key} should be bound to #{path}, got #{inspect(declared)}"
  end

  defp assert_attribute(id, key, expected, _component, attributes)
       when key in @computed_attributes do
    Matchers.assert_json_equal(
      expected,
      Map.fetch!(attributes, String.to_existing_atom(key)),
      "#{id}: #{key}"
    )
  end

  defp assert_attribute(id, key, _expected, _component, _attributes),
    do: flunk("#{id}: unknown accessibility attribute #{inspect(key)}")
end

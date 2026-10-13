defmodule A2UIConformance.SurfaceState do
  @moduledoc false

  # What a message-processing case may assert about a processor's
  # surfaces (reference harness `_assert_expected_surface_state`,
  # L720-809), and the component resolution it needs
  # (`_resolve_surface_components`, L669-717).
  #
  # Per `surfaces.<id>`: `exists`, `theme`, `sendDataModel`, `dataModel`,
  # `components` (a map by id, or a list — which also pins the component
  # count) and `validationResult`. Component properties are compared
  # after binding, as `str(actual) == str(expected)`.

  import ExUnit.Assertions

  alias A2UIConformance.{Matchers, PyStr}
  alias A2UICore.Catalog
  alias A2UICore.Processor
  alias A2UICore.Resolution.{Binder, DataContext}
  alias A2UICore.State.{Component, Components, Surface}

  @typedoc "A resolved component instance."
  @type instance :: %{type: String.t(), props: map()}

  @doc """
  Binds every component of `surface`, expanding collection templates.

  Instances are keyed by component id for the plain pass, and by
  `<id>_<index>` and `<id>-[<scoped path>]` for each template item.
  Returns the instances and the warnings/errors raised on the way.
  """
  @spec resolve(Surface.t()) :: {%{optional(String.t()) => instance()}, [DataContext.effect()]}
  def resolve(%Surface{} = surface) do
    surface.components
    |> Components.ids()
    |> Enum.reduce({%{}, []}, fn id, acc -> resolve_one(surface, id, "/", id, acc) end)
  end

  defp resolve_one(surface, component_id, data_path, key, {resolved, effects} = acc) do
    with false <- Map.has_key?(resolved, key),
         %Component{} = component <- Components.get(surface.components, component_id) do
      catalog =
        Map.get(surface.catalogs, component.catalog_id) || Surface.default_catalog(surface)

      context = DataContext.for_surface(surface, path: data_path)
      {props, more} = Binder.bind(context, component, catalog)

      {resolved, effects} =
        {resolved, effects ++ more}
        |> expand_templates(surface, context, props)
        |> expand_indexed_children(surface, component, catalog, data_path)

      {Map.put(resolved, key, %{type: component.type, props: props}), effects}
    else
      _already_resolved_or_unknown -> acc
    end
  end

  # A `{componentId, path}` property: the component is instantiated once
  # per item of the array at `path`.
  defp expand_templates(acc, surface, context, props) do
    Enum.reduce(props, acc, fn
      {_key, %{"componentId" => template_id, "path" => path}}, acc when is_binary(path) ->
        resolved_path = DataContext.resolve_path(context, path)

        case Surface.get_data(surface, resolved_path) do
          {:ok, items} when is_list(items) ->
            expand_items(acc, surface, template_id, resolved_path, items)

          _not_a_list ->
            acc
        end

      _other, acc ->
        acc
    end)
  end

  defp expand_items(acc, surface, template_id, path, items) do
    base = String.trim_trailing(path, "/")

    items
    |> Enum.with_index()
    |> Enum.reduce(acc, fn {_item, index}, acc ->
      scoped = "#{base}/#{index}"

      acc
      |> then(&resolve_one(surface, template_id, scoped, "#{template_id}_#{index}", &1))
      |> then(&resolve_one(surface, template_id, scoped, "#{template_id}-[#{scoped}]", &1))
    end)
  end

  # Inside an item scope (`…/<index>`), the component's own children are
  # instantiated for that item too.
  defp expand_indexed_children(acc, surface, component, catalog, data_path) do
    last = data_path |> String.trim("/") |> String.split("/", trim: true) |> List.last()

    if is_binary(last) and Regex.match?(~r/\A[0-9]+\z/, last) do
      spec = if catalog, do: Catalog.ref_spec(catalog, component.type)
      known = Components.ids(surface.components)

      component
      |> Component.child_references(spec, known)
      |> Enum.reduce(acc, fn {child_id, _path}, acc ->
        acc
        |> then(&resolve_one(surface, child_id, data_path, "#{child_id}_#{last}", &1))
        |> then(&resolve_one(surface, child_id, data_path, "#{child_id}-[#{data_path}]", &1))
      end)
    else
      acc
    end
  end

  @doc """
  The first error raised while resolving any surface's components, as
  the message the reference harness would raise, or `nil`.
  """
  @spec first_resolution_error(Processor.t()) :: String.t() | nil
  def first_resolution_error(%Processor{} = processor) do
    processor
    |> Processor.surfaces()
    |> Enum.flat_map(fn surface -> surface |> resolve() |> elem(1) end)
    |> Enum.find_value(fn
      {:error, payload} -> payload[:message] || "Expression error"
      _warning -> nil
    end)
  end

  @doc """
  Asserts an `expect` block against the processor's surfaces.
  """
  @spec assert_state(Processor.t(), term()) :: :ok
  def assert_state(%Processor{} = processor, %{"surfaces" => %{} = surfaces}) do
    for {id, expected} <- surfaces, do: assert_surface(processor, id, expected)
    :ok
  end

  def assert_state(%Processor{}, _expected), do: :ok

  defp assert_surface(processor, id, expected) do
    surface = Processor.surface(processor, id)

    if expected["exists"] == false do
      assert surface == nil, "surface '#{id}' should not exist"
    else
      assert surface != nil, "surface '#{id}' does not exist"
      assert_header(surface, expected)
      assert_components(surface, expected["components"])
      assert_validation_results(surface, expected["validationResult"])
    end
  end

  defp assert_header(surface, expected) do
    if Map.has_key?(expected, "theme"),
      do: Matchers.assert_json_equal(expected["theme"], surface.theme, "theme of '#{surface.id}'")

    if Map.has_key?(expected, "sendDataModel"),
      do: assert(surface.send_data_model == expected["sendDataModel"])

    if Map.has_key?(expected, "dataModel") do
      {:ok, data} = Surface.get_data(surface, "/")
      Matchers.assert_json_equal(expected["dataModel"], data, "data model of '#{surface.id}'")
    end
  end

  defp assert_components(_surface, nil), do: :ok

  defp assert_components(surface, expected) do
    items = expected_components(expected)
    {nodes, _effects} = resolve(surface)

    for {id, spec} <- items, do: assert_component(surface, nodes, id, spec)

    present? = fn id -> Components.get(surface.components, id) != nil end

    if is_list(expected) and Enum.all?(items, fn {id, _spec} -> present?.(id) end) do
      actual = Components.size(surface.components)

      assert actual == length(items),
             "surface '#{surface.id}' component count mismatch: expected " <>
               "#{length(items)}, got #{actual}"
    end

    :ok
  end

  defp expected_components(%{} = by_id), do: Map.to_list(by_id)

  defp expected_components(list) when is_list(list),
    do: for(%{} = spec <- list, do: {spec["id"], spec})

  defp expected_components(_other), do: []

  defp assert_component(surface, nodes, id, spec) do
    component = if is_binary(id), do: Components.get(surface.components, id)
    node = Map.get(nodes, id)

    assert component != nil or node != nil,
           "component '#{id}' missing from surface '#{surface.id}'"

    if is_map(spec) do
      type = if component, do: component.type, else: node.type

      if Map.has_key?(spec, "component"),
        do: assert(type == spec["component"], "component '#{id}' is a #{type}")

      if node, do: assert_properties(id, node.props, spec)
    end
  end

  defp assert_properties(id, props, spec) do
    for {key, expected} <- spec, key not in ["id", "component"] do
      actual = Map.get(props, key)

      assert PyStr.str(actual) == PyStr.str(expected),
             "property '#{key}' mismatch on component '#{id}': got #{inspect(actual)}, " <>
               "expected #{inspect(expected)}"
    end
  end

  defp assert_validation_results(_surface, nil), do: :ok

  defp assert_validation_results(surface, expected) do
    {nodes, _effects} = resolve(surface)

    for {id, result} <- expected do
      node = Map.get(nodes, id)
      assert node != nil, "component node '#{id}' missing from surface '#{surface.id}'"

      Matchers.assert_json_equal(
        result,
        node.props["validationResult"],
        "validationResult of '#{id}'"
      )
    end

    :ok
  end
end

defmodule A2UIConformance.Handlers.Macros do
  @moduledoc false

  # The cases of conformance/agent/macros/macros.yaml
  # (python/a2ui_agent/tests/conformance/macro_suite.py and
  # test_macro_conformance.py).
  #
  # The suite's macros are defined here with the builder, as the
  # reference defines them in Python (the YAML templates are a sketch:
  # `StatusBadge` upper-cases its status, `ConfigCard` writes Python's
  # `str()` of its arguments); their parameters come from the YAML.
  #
  #   * `expand` — the case's components, in v0.9 messages (with a
  #     `createSurface` when the case names a catalog), go through
  #     `MacroExpander.to_transport/2`. The messages are first checked
  #     as envelopes, as the reference's typed models do. The result
  #     must equal the golden file, which must be valid; or the case
  #     expects an error.
  #   * `transform_catalog` — a macro named like a base component.
  #   * `transform_to_inference_catalog` — the inference catalog's
  #     components, union and properties.
  #   * `transform_to_inference` — messages pass through unchanged.

  @behaviour A2UIConformance.Handler

  import ExUnit.Assertions
  import A2UIAgent.Builder.Basic

  alias A2UIAgent.{Macro, MacroExpander}
  alias A2UIConformance.{Case, GoldenSuites, Matchers, PyStr}
  alias A2UICore.{Catalog, KeyOrder, Message}
  alias A2UICore.Catalog.Basic

  @impl true
  def run(%Case{action: action} = case, _context) do
    run_action(action, case, Basic.catalog("v0.9.1"))
    :ok
  end

  defp run_action("expand", %Case{suite: suite, raw: raw}, catalog) do
    version = raw["envelope_version"] || "v0.9"
    expander = MacroExpander.new(catalog, macros(raw["suite_macros"]))

    result =
      with {:ok, _operations} <- Message.decode(envelopes(raw, version), catalog: :permissive),
           do: MacroExpander.to_transport(expander, envelopes(raw, version))

    case {raw["expect_error"], result} do
      {nil, {:ok, messages}} ->
        golden = GoldenSuites.golden(suite, raw["golden"])
        Matchers.assert_json_equal(golden, messages, "expanded messages")
        GoldenSuites.assert_valid(golden, raw, catalogs(catalog, raw["catalog_id"]))

      {nil, {:error, error}} ->
        flunk("expansion failed: #{Exception.message(error)}")

      {expected, {:ok, messages}} ->
        error = validation_error(messages, raw, catalog)
        assert error, "expected an error, got #{inspect(messages)}"
        Matchers.assert_error(expected, error)

      {expected, {:error, error}} ->
        Matchers.assert_error(expected, error)
    end
  end

  defp run_action("transform_catalog", %Case{raw: raw}, catalog) do
    colliding =
      Macro.new(raw["colliding_macro"], [], fn _ -> card(child: text(text: "colliding")) end)

    result = catalog |> MacroExpander.new([colliding]) |> MacroExpander.inference_catalog()
    Matchers.assert_error(raw["expect_error"], result)
  end

  defp run_action("transform_to_inference_catalog", %Case{raw: raw}, catalog) do
    expander =
      MacroExpander.new(catalog, macros(raw["suite_macros"]),
        passthrough_components: raw["passthrough_components"]
      )

    assert {:ok, inference} = MacroExpander.inference_catalog(expander)
    Enum.each(raw["expect"] || %{}, &assert_expectation(&1, inference))
  end

  defp run_action("transform_to_inference", %Case{raw: raw}, catalog) do
    expander = MacroExpander.new(catalog, macros(raw["suite_macros"]))
    assert [message] = MacroExpander.to_inference(expander, envelopes(raw, "v0.9"))
    assert message["updateComponents"]["components"] == [raw["input"]]
  end

  defp envelopes(raw, version) do
    components = List.wrap(raw["input"])
    update = %{"surfaceId" => raw["surface_id"], "components" => components}

    create =
      case raw["catalog_id"] do
        nil ->
          []

        catalog_id ->
          [
            %{
              "version" => version,
              "createSurface" => %{"surfaceId" => raw["surface_id"], "catalogId" => catalog_id}
            }
          ]
      end

    create ++ [%{"version" => version, "updateComponents" => update}]
  end

  # A golden case's catalog id may name the basic catalog by another id.
  defp catalogs(catalog, nil), do: [catalog]
  defp catalogs(%Catalog{catalog_id: id} = catalog, id), do: [catalog]
  defp catalogs(catalog, catalog_id), do: [catalog, Catalog.derive(catalog, catalog_id)]

  defp validation_error(messages, raw, catalog) do
    GoldenSuites.assert_valid(messages, raw, catalogs(catalog, raw["catalog_id"]))
    nil
  rescue
    error in ExUnit.AssertionError ->
      A2UICore.Error.new(:validation, "VALIDATION_FAILED", error.message)
  end

  defp assert_expectation({"augmented_components", names}, catalog) do
    components = Catalog.validation_schema(catalog)["components"]
    for name <- names, do: assert(Map.has_key?(components, name), "#{name} is not a component")
  end

  defp assert_expectation({"absent_components", names}, catalog) do
    components = Catalog.validation_schema(catalog)["components"]
    for name <- names, do: refute(Map.has_key?(components, name), "#{name} is a component")
  end

  defp assert_expectation({"any_component_references", refs}, catalog) do
    targets = union_targets(catalog)
    for ref <- refs, do: assert(ref in targets, "#{ref} is not in anyComponent")
  end

  defp assert_expectation({"absent_any_component_references", names}, catalog) do
    targets = union_targets(catalog)

    for name <- names,
        do:
          refute(
            Enum.any?(targets, &String.ends_with?(&1, "/" <> name)),
            "#{name} is in anyComponent"
          )
  end

  defp assert_expectation({"component_properties", expected}, catalog) do
    components = catalog |> Catalog.to_json() |> KeyOrder.to_plain() |> Map.fetch!("components")

    for {component, properties} <- expected, {property, schema} <- properties do
      actual = get_in(components, [component, "properties", property])
      assert actual, "#{component} has no property #{property}"

      for {key, value} <- schema,
          do: assert(actual[key] == value, "#{component}.#{property}.#{key}")
    end
  end

  defp assert_expectation({"protocol_version", expected}, catalog),
    do: assert(String.trim_leading(catalog.protocol_version, "v") == expected)

  defp union_targets(catalog) do
    (get_in(Catalog.validation_schema(catalog), ["$defs", "anyComponent", "oneOf"]) || [])
    |> Enum.map(& &1["$ref"])
    |> Enum.filter(&is_binary/1)
  end

  # -- the suite's macros ----------------------------------------------------------

  defp macros(definitions) do
    for definition <- definitions || [] do
      Macro.new(
        definition["name"],
        Enum.map(definition["parameters"], &parameter/1),
        function(definition["name"]),
        description: definition["description"]
      )
    end
  end

  defp parameter({name, %{"type" => "string", "enum" => values}}),
    do: {String.to_atom(name), {:enum, values}}

  defp parameter({name, %{"type" => "check_rule_list"}}),
    do: {String.to_atom(name), {:list, :check_rule}}

  defp parameter({name, %{"type" => type}}), do: {String.to_atom(name), String.to_atom(type)}

  defp function("StatusBadge") do
    fn %{status: status, title: title} ->
      card(
        child:
          row(
            children: [
              text(text: String.upcase(status), variant: "caption"),
              text(text: title, variant: "h3")
            ]
          )
      )
    end
  end

  defp function("SlotContainer") do
    fn %{title: title, content: content} ->
      card(child: column(children: [text(text: title, variant: "h2"), content]))
    end
  end

  defp function("MultiSlotContainer") do
    fn %{header: header, items: items} ->
      card(child: column(children: [text(text: header, variant: "h2") | items]))
    end
  end

  defp function("ActionButton") do
    fn %{label: label, action: action} ->
      button(child: text(text: label), action: action, variant: "primary")
    end
  end

  defp function("BoundMetric") do
    fn %{label: label, value: value} ->
      card(
        child:
          column(
            children: [text(text: label, variant: "caption"), text(text: value, variant: "h1")]
          )
      )
    end
  end

  defp function("ConfigCard") do
    fn %{name: name, port: port, active: active} ->
      card(
        child:
          column(
            children: [
              text(text: name, variant: "h2"),
              text(text: "Port: #{PyStr.str(port)}", variant: "body"),
              text(text: "Active: #{PyStr.str(active)}", variant: "body")
            ]
          )
      )
    end
  end

  defp function("NestedMacroCard") do
    fn %{title: title, status: status} ->
      card(
        child:
          column(
            children: [
              text(text: title, variant: "h1"),
              Macro.call("StatusBadge", status: status, title: "#{title} Status")
            ]
          )
      )
    end
  end

  defp function("RecursiveCard") do
    fn %{title: title} -> card(child: Macro.call("RecursiveCard", title: title)) end
  end

  defp function("ComplexCard"), do: fn %{title: title} -> card(child: text(text: title)) end
end

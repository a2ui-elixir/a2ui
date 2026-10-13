defmodule A2UICore.Resolution.Binder do
  @moduledoc """
  Resolves a component's properties to the values a renderer displays.

  The component's catalog schema says how each property behaves:

    * *dynamic* (`DynamicString`, `DataBinding`, … — anything that may be
      a binding or a function call) — evaluated against the data model;
    * *action* — kept as the raw action object, to be resolved with
      `A2UICore.Resolution.DataContext.resolve_action/2` when triggered;
    * *structural* (`ChildList`, `ComponentId`, templates) — kept as is,
      for the node resolver to expand;
    * *checkable* — the rule list is kept and the owning object gains
      `"isValid"`, `"validationErrors"` and `"validationResult"`;
    * objects and arrays are resolved member by member.

  Where the schema says nothing (a component whose schema is an `allOf`
  envelope, an unknown component, a property the schema does not
  declare) the behavior is inferred from the value's shape, as the
  reference binder does.

  The result is a snapshot: `bind/4` is pure and returns the resolved
  properties together with the warnings and errors raised while
  evaluating them (`t:A2UICore.Resolution.DataContext.effect/0`).
  Reactive updates are the host's job — it rebinds when the data model or
  the component changes.
  """

  alias A2UICore.Catalog
  alias A2UICore.CommonTypes
  alias A2UICore.Resolution.DataContext
  alias A2UICore.State.Component

  @moduledoc since: "0.1.0"

  @checkable_refs ["Checkable", "CheckRule"]
  @action_refs ["Action"]
  @structural_refs ["ChildList", "ComponentId", "Child", "TemplateChildList"]
  @special [:checkable, :action, :structural, :dynamic]
  @severities ["error", "warning", "info"]

  @typedoc "How a property behaves at runtime."
  @type behavior ::
          :dynamic
          | :action
          | :structural
          | :checkable
          | :static
          | {:object, %{optional(String.t()) => behavior()}}
          | {:array, behavior()}

  @doc """
  Resolves `component`'s properties in `context`.

  `catalog` supplies the component's schema (`nil` or a catalog without
  the component falls back to shape inference). Option `:schema`
  overrides the component schema.
  """
  @spec bind(DataContext.t(), Component.t(), Catalog.t() | nil, keyword()) ::
          {map(), [DataContext.effect()]}
  def bind(%DataContext{} = context, %Component{} = component, catalog, options \\ []) do
    shape = shape(catalog, component.type, options[:schema])
    bind_object(component.props, shape, context)
  end

  @doc """
  The behavior of a schema: `:dynamic`, `:action`, `:structural`,
  `:checkable`, `:static`, `{:object, shape}` or `{:array, element}`.

  `defs` are the definitions its `$ref`s resolve against.
  """
  @spec classify(term(), map()) :: behavior()
  def classify(schema, defs), do: classify(schema, defs, CommonTypes.dynamic_definitions())

  # -- schema classification ----------------------------------------------------

  defp shape(catalog, type, schema_override) do
    schema = schema_override || component_schema(catalog, type)

    if is_map(schema) do
      defs = Map.merge(catalog_defs(catalog), Map.get(schema, "$defs") || %{})

      case classify(schema, defs) do
        {:object, shape} -> shape
        _not_an_object -> %{}
      end
    else
      %{}
    end
  end

  defp component_schema(%Catalog{} = catalog, type) do
    case Catalog.get_component(catalog, type) do
      nil -> nil
      component -> component.schema
    end
  end

  defp component_schema(_catalog, _type), do: nil

  defp catalog_defs(%Catalog{defs: defs}) when is_map(defs), do: defs
  defp catalog_defs(_catalog), do: %{}

  defp classify(schema, defs, dynamic) when is_map(schema) do
    with :none <- classify_ref(schema, defs, dynamic),
         :none <- classify_combiners(schema, defs, dynamic),
         :none <- classify_container(schema, defs, dynamic) do
      :static
    end
  end

  defp classify(_schema, _defs, _dynamic), do: :static

  defp classify_ref(%{"$ref" => ref}, defs, dynamic) when is_binary(ref) do
    name = ref_name(ref)

    cond do
      name in @checkable_refs -> :checkable
      name in @action_refs -> :action
      name in @structural_refs -> :structural
      MapSet.member?(dynamic, name) -> :dynamic
      String.contains?(ref, "$defs/") and dynamic_def?(Map.get(defs, name)) -> :dynamic
      true -> :none
    end
  end

  defp classify_ref(_schema, _defs, _dynamic), do: :none

  # The last path segment of the fragment (or of the whole reference
  # when it has none): `common_types.json#/$defs/DynamicString` → `DynamicString`.
  defp ref_name(ref) do
    target = ref |> String.split("#") |> List.last()
    target |> String.split("/", trim: true) |> List.last() || ""
  end

  # A def that accepts a data binding and a function call next to literals.
  defp dynamic_def?(%{} = schema) do
    case schema["oneOf"] || schema["anyOf"] do
      branches when is_list(branches) ->
        Enum.any?(branches, &(local_ref(&1) == "DataBinding")) and
          Enum.any?(branches, &function_call?/1)

      _not_a_union ->
        false
    end
  end

  defp dynamic_def?(_schema), do: false

  defp function_call?(%{"allOf" => branches}) when is_list(branches),
    do: Enum.any?(branches, &(local_ref(&1) == "FunctionCall"))

  defp function_call?(branch), do: local_ref(branch) == "FunctionCall"

  defp local_ref(%{"$ref" => ref}) when is_binary(ref), do: ref_name(ref)
  defp local_ref(_branch), do: nil

  defp classify_combiners(schema, defs, dynamic) do
    Enum.find_value(["oneOf", "anyOf", "allOf"], :none, fn combiner ->
      case schema[combiner] do
        branches when is_list(branches) -> first_special(branches, defs, dynamic)
        _no_branches -> nil
      end
    end)
  end

  defp first_special(branches, defs, dynamic) do
    Enum.find_value(branches, fn
      %{} = branch ->
        behavior = classify(branch, defs, dynamic)
        if behavior in @special, do: behavior

      _other ->
        nil
    end)
  end

  defp classify_container(schema, defs, dynamic) do
    cond do
      schema["type"] == "array" or Map.has_key?(schema, "items") ->
        array_behavior(schema["items"], defs, dynamic)

      schema["type"] == "object" or Map.has_key?(schema, "properties") ->
        object_behavior(schema["properties"], defs, dynamic)

      true ->
        :none
    end
  end

  defp array_behavior(items, defs, dynamic) do
    element = if is_map(items), do: classify(items, defs, dynamic), else: :static
    if element == :checkable, do: :checkable, else: {:array, element}
  end

  defp object_behavior(%{} = properties, defs, dynamic) do
    cond do
      Map.has_key?(properties, "componentId") and
          (Map.has_key?(properties, "path") or Map.has_key?(properties, "dataBinding")) ->
        :structural

      Map.has_key?(properties, "explicitList") or Map.has_key?(properties, "template") ->
        :structural

      Map.has_key?(properties, "condition") ->
        :checkable

      true ->
        shape =
          for {key, schema} <- properties, is_map(schema), into: %{} do
            {key, classify(schema, defs, dynamic)}
          end

        {:object, shape}
    end
  end

  defp object_behavior(_properties, _defs, _dynamic), do: :none

  # -- value shape fallback -----------------------------------------------------

  defp fallback("checks", _value, _v1?), do: :checkable

  defp fallback(_key, [%{} = first | _rest], _v1?) when is_map_key(first, "condition"),
    do: :checkable

  defp fallback(_key, %{} = value, v1?) do
    cond do
      Map.has_key?(value, "condition") ->
        :checkable

      Map.has_key?(value, "componentId") and has_any?(value, ["path", "dataBinding"]) ->
        :structural

      has_any?(value, if(v1?, do: ["@path", "@call"], else: ["path", "call"])) ->
        :dynamic

      has_any?(value, ["event", "functionCall"]) ->
        :action

      true ->
        {:object, Map.new(value, fn {key, item} -> {key, fallback(key, item, v1?)} end)}
    end
  end

  defp fallback(_key, [first | _rest], v1?), do: {:array, fallback("", first, v1?)}
  defp fallback(_key, [], _v1?), do: {:array, :static}

  defp fallback(_key, value, _v1?) when is_binary(value) do
    if String.contains?(value, "${"), do: :dynamic, else: :static
  end

  defp fallback(_key, _value, _v1?), do: :static

  defp has_any?(map, keys), do: Enum.any?(keys, &Map.has_key?(map, &1))

  # -- binding ------------------------------------------------------------------

  defp bind_object(object, shape, context) do
    v1? = DataContext.v1?(context)

    Enum.reduce(object, {%{}, []}, fn {key, value}, {result, effects} ->
      behavior = Map.get(shape, key) || fallback(key, value, v1?)
      {resolved, extras, more} = bind_value(value, behavior, context)
      {result |> Map.put(key, resolved) |> Map.merge(extras), effects ++ more}
    end)
  end

  # Returns `{value, properties to add to the owning object, effects}`.
  defp bind_value(nil, _behavior, _context), do: {nil, %{}, []}

  defp bind_value(value, :dynamic, context) do
    {resolved, effects} = DataContext.resolve_dynamic_value(context, value)
    {resolved, %{}, effects}
  end

  defp bind_value(value, :checkable, context), do: bind_checks(value, context)

  defp bind_value(value, {:array, element}, context) when is_list(value) do
    {items, effects} =
      Enum.map_reduce(value, [], fn item, effects ->
        {resolved, _extras, more} = bind_value(item, element, context)
        {resolved, effects ++ more}
      end)

    {items, %{}, effects}
  end

  defp bind_value(value, {:object, shape}, context) when is_map(value) do
    {resolved, effects} = bind_object(value, shape, context)
    {resolved, %{}, effects}
  end

  defp bind_value(value, _behavior, _context), do: {value, %{}, []}

  defp bind_checks(value, context) do
    rules = if is_list(value), do: value, else: []

    {results, effects} =
      Enum.map_reduce(rules, [], fn rule, effects ->
        {result, more} = evaluate_rule(rule, context)
        {result, effects ++ more}
      end)

    failed = Enum.reject(results, & &1["valid"])

    extras = %{
      "isValid" => failed == [],
      "validationErrors" =>
        for(result <- failed, message = result["message"], message not in [nil, ""], do: message),
      "validationResult" => List.first(failed) || %{"valid" => true}
    }

    {value, extras, effects}
  end

  defp evaluate_rule(rule, context) do
    {condition, message} =
      case rule do
        %{} -> {Map.get(rule, "condition", rule), Map.get(rule, "message", "Validation failed")}
        _not_an_object -> {rule, "Validation failed"}
      end

    {value, effects} = DataContext.resolve_dynamic_value(context, condition)
    {rule_result(value, message), effects}
  end

  defp rule_result(value, fallback) do
    raw = if is_map(value), do: value, else: %{"valid" => truthy?(value)}

    raw =
      if not truthy?(raw["valid"]) and not truthy?(raw["message"]) and fallback not in [nil, ""],
        do: Map.put(raw, "message", fallback),
        else: raw

    case validation_result(raw) do
      {:ok, result} -> result
      :error -> %{"valid" => false, "message" => fallback || "Validation failed"}
    end
  end

  defp truthy?(value), do: value not in [nil, false, 0, 0.0, "", [], %{}]

  # `ValidationResult`: `valid` (boolean, required), optional `code`,
  # `message` and `severity`; nothing else; absent values are dropped.
  defp validation_result(%{} = raw) do
    with true <- Enum.all?(Map.keys(raw), &(&1 in ["valid", "code", "message", "severity"])),
         {:ok, valid} <- boolean(raw["valid"]),
         true <- string_or_nil?(raw["code"]),
         true <- string_or_nil?(raw["message"]),
         true <- raw["severity"] in [nil | @severities] do
      result =
        for {key, value} <- %{
              "valid" => valid,
              "code" => raw["code"],
              "message" => raw["message"],
              "severity" => raw["severity"]
            },
            value != nil,
            into: %{},
            do: {key, value}

      {:ok, result}
    else
      _invalid -> :error
    end
  end

  defp boolean(value) when is_boolean(value), do: {:ok, value}
  defp boolean(value) when value in [1, "1", "true", "yes", "on", "t", "y"], do: {:ok, true}
  defp boolean(value) when value in [0, "0", "false", "no", "off", "f", "n"], do: {:ok, false}
  defp boolean(_value), do: :error

  defp string_or_nil?(value), do: is_nil(value) or is_binary(value)
end

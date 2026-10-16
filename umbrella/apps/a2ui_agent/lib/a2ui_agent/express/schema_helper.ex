defmodule A2UIAgent.Express.SchemaHelper do
  @moduledoc """
  What Express reads from a catalog: each component's properties in
  positional order, each function's parameters, and the facts about a
  property's schema that decide how an argument compiles.

  A component's positional order is its own properties in the order its
  schema declares them, then the properties it inherits through `allOf`,
  leaving out `id`, `component` and `catalogId`. A component can take
  checks when it declares a property holding a list of `CheckRule`s, or
  inherits one from a common type such as `Checkable`; an inherited
  check property comes last.

  The helper reads the catalog document (`A2UICore.Catalog.to_json/2`,
  in the order it was read) with its local and peer references written
  inline, and resolves references to the common types against the common
  types of the protocol version it is built for.
  """

  alias A2UICore.{Catalog, KeyOrder}
  alias A2UICore.Schema.Source

  @moduledoc since: "0.1.0"

  @envelope ~w(component id catalogId)

  defstruct [
    :catalog,
    :catalog_id,
    :document,
    :keys,
    common_defs: %{},
    component_names: [],
    function_names: [],
    components: %{},
    functions: %{},
    component_properties: %{},
    component_required: %{},
    check_properties: %{},
    inherited_check_schemas: %{},
    property_enums: %{},
    function_properties: %{},
    function_required: %{}
  ]

  @type t :: %__MODULE__{
          catalog: Catalog.t(),
          catalog_id: String.t(),
          document: term(),
          keys: %{path: String.t(), call: String.t()},
          common_defs: term(),
          component_names: [String.t()],
          function_names: [String.t()],
          components: %{optional(String.t()) => term()},
          functions: %{optional(String.t()) => term()},
          component_properties: %{optional(String.t()) => [String.t()]},
          component_required: %{optional(String.t()) => [String.t()]},
          check_properties: %{optional(String.t()) => String.t()},
          inherited_check_schemas: %{optional(String.t()) => term()},
          property_enums: %{optional({String.t(), String.t()}) => list()},
          function_properties: %{optional(String.t()) => [String.t()]},
          function_required: %{optional(String.t()) => [String.t()]}
        }

  @doc """
  The helpers for `catalogs`, in order, built for protocol `version`.
  The catalogs are first linked to each other
  (`A2UICore.Catalog.link_catalogs/1`), so that references between them
  resolve.
  """
  @spec build_all([Catalog.t()], String.t()) :: [t()]
  def build_all(catalogs, version),
    do: catalogs |> Catalog.link_catalogs() |> Enum.map(&new(&1, version))

  @doc "The helper for one catalog, built for protocol `version`."
  @spec new(Catalog.t(), String.t()) :: t()
  def new(%Catalog{} = catalog, version) do
    ordered = Catalog.to_json(catalog, ordered: true)
    document = Catalog.inline_refs(catalog, ordered, ordered, ordered: true)
    common = Source.ordered_document(version, :common_types)

    helper = %__MODULE__{
      catalog: catalog,
      catalog_id: catalog.catalog_id,
      document: document,
      keys: reserved_keys(version),
      common_defs: KeyOrder.get(common, "$defs") || %{}
    }

    {component_names, components} = entries(KeyOrder.get(document, "components"))
    {function_names, functions} = entries(KeyOrder.get(document, "functions"))

    helper = %{
      helper
      | component_names: component_names,
        components: components,
        function_names: function_names,
        functions: functions
    }

    helper = Enum.reduce(component_names, helper, &load_component/2)
    Enum.reduce(function_names, helper, &load_function/2)
  end

  defp entries(node) do
    named = for {name, schema} <- pairs(node), is_map(schema), do: {name, schema}
    {Enum.map(named, &elem(&1, 0)), Map.new(named)}
  end

  @doc """
  The keys that mark a data binding and a function call in `version`:
  `@path` and `@call` from v1.0, `path` and `call` before.
  """
  @spec reserved_keys(String.t()) :: %{path: String.t(), call: String.t()}
  def reserved_keys(version) do
    if A2UICore.SemVer.at_least(version, "v1.0"),
      do: %{path: "@path", call: "@call"},
      else: %{path: "path", call: "call"}
  end

  # -- loading ---------------------------------------------------------------------------

  defp load_component(name, helper) do
    sub_schemas = component_sub_schemas(Map.fetch!(helper.components, name))
    own_check = Enum.find_value(sub_schemas, &own_check_property/1)

    inherited =
      if own_check, do: nil, else: Enum.find_value(sub_schemas, &inherited_check(helper, &1))

    {props, required, enums} =
      Enum.reduce(sub_schemas, {[], [], %{}}, &add_sub_schema(name, &1, &2))

    ordered = props -- @envelope

    {ordered, helper} =
      case {own_check, inherited} do
        {own, _} when is_binary(own) ->
          {ordered, put_in(helper.check_properties[name], own)}

        {nil, {key, schema}} ->
          helper = put_in(helper.check_properties[name], key)
          helper = put_in(helper.inherited_check_schemas[name], schema)
          {if(key in ordered, do: ordered, else: ordered ++ [key]), helper}

        {nil, nil} ->
          {ordered, helper}
      end

    %{
      helper
      | component_properties: Map.put(helper.component_properties, name, ordered),
        component_required: Map.put(helper.component_required, name, required),
        property_enums: Map.merge(helper.property_enums, enums)
    }
  end

  defp add_sub_schema(name, sub, {props, required, enums}) do
    {props, enums} =
      sub
      |> KeyOrder.get("properties")
      |> pairs()
      |> Enum.reduce({props, enums}, &add_property(name, &1, &2))

    {props, union(required, KeyOrder.get(sub, "required")), enums}
  end

  defp add_property(name, {key, schema}, {props, enums}) do
    if key in props,
      do: {props, enums},
      else: {props ++ [key], put_enum(enums, {name, key}, find_enum(schema))}
  end

  defp put_enum(enums, _key, nil), do: enums
  defp put_enum(enums, key, values), do: Map.put(enums, key, values)

  defp union(names, more) when is_list(more),
    do: names ++ Enum.reject(Enum.uniq(more), &(&1 in names))

  defp union(names, _more), do: names

  defp own_check_property(sub) do
    if KeyOrder.has_key?(sub, "$ref"),
      do: nil,
      else: first_key(KeyOrder.get(sub, "properties"), &check_rule_list?/1)
  end

  defp inherited_check(helper, sub) do
    with name when is_binary(name) <- common_def_name(KeyOrder.get(sub, "$ref")),
         common when is_map(common) <- KeyOrder.get(helper.common_defs, name),
         properties = KeyOrder.get(common, "properties"),
         key when is_binary(key) <- first_key(properties, &inherited_check_rule_list?/1) do
      {key, KeyOrder.get(properties, key)}
    else
      _none -> nil
    end
  end

  # The first property whose schema passes `test`.
  defp first_key(properties, test),
    do: Enum.find_value(pairs(properties), fn {key, schema} -> if test.(schema), do: key end)

  defp check_rule_list?(schema) do
    is_map(schema) and KeyOrder.get(schema, "type") == "array" and
      common_def_name(KeyOrder.get(KeyOrder.get(schema, "items"), "$ref")) == "CheckRule"
  end

  # Inside the common types, `CheckRule` is a local reference.
  defp inherited_check_rule_list?(schema) do
    ref = KeyOrder.get(KeyOrder.get(schema, "items"), "$ref")

    is_map(schema) and KeyOrder.get(schema, "type") == "array" and
      (ref in ["#/$defs/CheckRule", "#/definitions/CheckRule"] or
         common_def_name(ref) == "CheckRule")
  end

  # The schemas a component's properties come from: the ones that declare
  # `component` first, then the ones it inherits, each followed by the
  # members of its own `allOf`. Local references are already inline.
  defp component_sub_schemas(schema) do
    declares = fn node -> node |> KeyOrder.get("properties") |> has?("component") end
    members = schema |> KeyOrder.get("allOf") |> List.wrap() |> Enum.filter(&is_map/1)

    {specific, inherited} = Enum.split_with(members, declares)

    own =
      cond do
        declares.(schema) -> [:root]
        specific == [] and is_map(KeyOrder.get(schema, "properties")) -> [:root]
        true -> []
      end

    Enum.flat_map(own ++ specific ++ inherited, fn
      :root -> [schema]
      member -> expand(member)
    end)
  end

  defp expand(node) do
    children = node |> KeyOrder.get("allOf") |> List.wrap() |> Enum.filter(&is_map/1)
    [node | Enum.flat_map(children, &expand/1)]
  end

  defp load_function(name, helper) do
    sub_schemas = function_sub_schemas(Map.fetch!(helper.functions, name))

    {props, required} = Enum.reduce(sub_schemas, {[], []}, &add_arguments/2)

    %{
      helper
      | function_properties: Map.put(helper.function_properties, name, props),
        function_required: Map.put(helper.function_required, name, required)
    }
  end

  defp add_arguments(sub, {props, required}) do
    args = sub |> KeyOrder.get("properties") |> KeyOrder.get("args")
    names = args |> KeyOrder.get("properties") |> pairs() |> Enum.map(&elem(&1, 0))
    more = KeyOrder.get(args, "required")
    {props ++ (names -- props), if(is_list(more), do: required ++ more, else: required)}
  end

  # The function schema, then the members of its `allOf`.
  defp function_sub_schemas(schema),
    do: [schema | schema |> KeyOrder.get("allOf") |> List.wrap() |> Enum.filter(&is_map/1)]

  # -- queries ---------------------------------------------------------------------------

  @doc "Whether the catalog defines component `name`."
  @spec component?(t(), String.t()) :: boolean()
  def component?(%__MODULE__{components: components}, name), do: Map.has_key?(components, name)

  @doc "Whether the catalog defines function `name`."
  @spec function?(t(), String.t()) :: boolean()
  def function?(%__MODULE__{functions: functions}, name), do: Map.has_key?(functions, name)

  @doc "A component's properties in positional order."
  @spec component_properties(t(), String.t()) :: [String.t()]
  def component_properties(helper, name), do: Map.get(helper.component_properties, name, [])

  @doc "The properties a component requires."
  @spec component_required(t(), String.t()) :: [String.t()]
  def component_required(helper, name), do: Map.get(helper.component_required, name, [])

  @doc "The property a component's checks go in, or `nil` if it takes none."
  @spec check_property(t(), String.t()) :: String.t() | nil
  def check_property(helper, name), do: Map.get(helper.check_properties, name)

  @doc "A function's parameters in positional order."
  @spec function_properties(t(), String.t()) :: [String.t()]
  def function_properties(helper, name), do: Map.get(helper.function_properties, name, [])

  @doc "The parameters a function requires."
  @spec function_required(t(), String.t()) :: [String.t()]
  def function_required(helper, name), do: Map.get(helper.function_required, name, [])

  @doc "The values a component property's schema enumerates, or `nil`."
  @spec property_enum(t(), String.t(), String.t()) :: list() | nil
  def property_enum(helper, component, property),
    do: Map.get(helper.property_enums, {component, property})

  @doc "The schema of a component property, or `nil`."
  @spec property_schema(t(), String.t(), String.t()) :: term()
  def property_schema(helper, component, property) do
    case Map.fetch(helper.components, component) do
      {:ok, schema} ->
        schema
        |> component_sub_schemas()
        |> Enum.map(&KeyOrder.get(&1, "properties"))
        |> find_property(property)

      :error ->
        nil
    end
  end

  defp find_property(property_maps, property) do
    Enum.find_value(property_maps, fn properties ->
      if has?(properties, property), do: KeyOrder.get(properties, property)
    end)
  end

  @doc "The schema of a function parameter, or `nil`."
  @spec function_property_schema(t(), String.t(), String.t()) :: term()
  def function_property_schema(helper, function, property) do
    case Map.fetch(helper.functions, function) do
      {:ok, schema} ->
        schema
        |> function_sub_schemas()
        |> Enum.map(fn sub ->
          sub |> KeyOrder.get("properties") |> KeyOrder.get("args") |> KeyOrder.get("properties")
        end)
        |> find_property(property)

      :error ->
        nil
    end
  end

  @doc "A component's description, from its schema or the first `allOf` member that has one."
  @spec component_description(t(), String.t()) :: String.t() | nil
  def component_description(helper, name) do
    schema = Map.get(helper.components, name)

    case KeyOrder.get(schema, "description") do
      description when is_binary(description) ->
        description

      _none ->
        schema
        |> KeyOrder.get("allOf")
        |> List.wrap()
        |> Enum.find_value(&string_or_nil(KeyOrder.get(&1, "description")))
    end
  end

  @doc "A function's description, or `nil`."
  @spec function_description(t(), String.t()) :: String.t() | nil
  def function_description(helper, name),
    do: helper.functions |> Map.get(name) |> KeyOrder.get("description") |> string_or_nil()

  defp string_or_nil(value) when is_binary(value), do: value
  defp string_or_nil(_value), do: nil

  @doc """
  Whether a value written for `schema` may be a data binding: the
  schema, or one it reaches through `$ref`, `allOf`, `oneOf` or `anyOf`,
  is an object schema with a `path` or `@path` property.
  """
  @spec admits_path?(t(), term()) :: boolean()
  def admits_path?(helper, schema), do: admits?(helper, schema, false, %{})

  # `seen` holds the references followed on the way, so that a cycle ends.
  defp admits?(helper, schema, in_common, seen) when is_map(schema) do
    properties = KeyOrder.get(schema, "properties")

    has?(properties, "path") or has?(properties, "@path") or
      follow_admits?(helper, schema, in_common, seen) or
      Enum.any?(combinators(schema), &admits?(helper, &1, in_common, seen))
  end

  defp admits?(_helper, _schema, _in_common, _seen), do: false

  defp follow_admits?(helper, schema, in_common, seen) do
    case follow(helper, schema, in_common) do
      {target, common} ->
        visit = {common, KeyOrder.get(schema, "$ref")}

        not Map.has_key?(seen, visit) and
          admits?(helper, target, common, Map.put(seen, visit, true))

      nil ->
        false
    end
  end

  @doc """
  The schema at `key` below `schema`: the item schema for `"items"`,
  else the schema of property `key` (or of any additional property),
  found through `$ref`, `allOf`, `oneOf` and `anyOf`. `nil` when the
  schema declares none.
  """
  @spec subschema(t(), term(), String.t()) :: term()
  def subschema(helper, schema, key), do: subschema(helper, schema, key, false, %{})

  defp subschema(helper, schema, key, in_common, seen) when is_map(schema) do
    own =
      if key == "items" do
        object_or_nil(KeyOrder.get(schema, "items"))
      else
        properties = KeyOrder.get(schema, "properties")

        object_or_nil(if has?(properties, key), do: KeyOrder.get(properties, key)) ||
          object_or_nil(KeyOrder.get(schema, "additionalProperties"))
      end

    own || followed_subschema(helper, schema, key, in_common, seen) ||
      Enum.find_value(combinators(schema), &subschema(helper, &1, key, in_common, seen))
  end

  defp subschema(_helper, _schema, _key, _in_common, _seen), do: nil

  defp followed_subschema(helper, schema, key, in_common, seen) do
    with {target, common} <- follow(helper, schema, in_common),
         visit = {common, KeyOrder.get(schema, "$ref")},
         false <- Map.has_key?(seen, visit) do
      subschema(helper, target, key, common, Map.put(seen, visit, true))
    else
      _none -> nil
    end
  end

  defp object_or_nil(value) when is_map(value), do: value
  defp object_or_nil(_value), do: nil

  # Where a schema's `$ref` leads: {target, whether it is in the common types}.
  defp follow(helper, schema, in_common) do
    ref = KeyOrder.get(schema, "$ref")

    cond do
      not is_binary(ref) ->
        nil

      name = common_def_name(ref) ->
        found(KeyOrder.get(helper.common_defs, name), true)

      in_common and String.starts_with?(ref, ["#/$defs/", "#/definitions/"]) ->
        name = ref |> String.split("/") |> List.last()
        found(KeyOrder.get(helper.common_defs, name), true)

      String.starts_with?(ref, "#/") ->
        found(query(helper.document, ref), false)

      true ->
        nil
    end
  end

  defp found(target, common) when is_map(target), do: {target, common}
  defp found(_target, _common), do: nil

  defp combinators(schema) do
    Enum.flat_map(["allOf", "oneOf", "anyOf"], fn key ->
      case KeyOrder.get(schema, key) do
        list when is_list(list) -> list
        _none -> []
      end
    end)
  end

  @doc """
  The name of the common type a `$ref` points to
  (`common_types.json#/$defs/<Name>`, also as an absolute URL or under
  `definitions`), or `nil`.

      iex> A2UIAgent.Express.SchemaHelper.common_def_name("common_types.json#/$defs/Action")
      "Action"
      iex> A2UIAgent.Express.SchemaHelper.common_def_name("#/$defs/Action")
      nil
  """
  @spec common_def_name(term()) :: String.t() | nil
  def common_def_name(ref) when is_binary(ref) do
    case Regex.run(~r{(?:^|/)common_types\.json#/(?:\$defs|definitions)/(\w+)$}, ref) do
      [_whole, name] -> name
      nil -> nil
    end
  end

  def common_def_name(_ref), do: nil

  @doc """
  Whether a property takes an action: its schema refers to the common
  `Action` type, directly or through `allOf`, `oneOf` or `anyOf`.
  """
  @spec action_slot?(term()) :: boolean()
  def action_slot?(schema) when is_map(schema) do
    common_def_name(KeyOrder.get(schema, "$ref")) == "Action" or
      Enum.any?(combinators(schema), &action_slot?/1)
  end

  def action_slot?(_schema), do: false

  @doc """
  Whether a property holds a list of option objects (items with `label`
  and `value` properties), so that plain strings are written as options.
  """
  @spec option_objects?(term()) :: boolean()
  def option_objects?(schema) when is_map(schema) do
    if KeyOrder.has_key?(schema, "items"),
      do: label_value?(KeyOrder.get(schema, "items")),
      else: Enum.any?(combinators(schema), &option_objects?/1)
  end

  def option_objects?(_schema), do: false

  defp label_value?(schema) when is_map(schema) do
    properties = KeyOrder.get(schema, "properties")

    (is_map(properties) and has?(properties, "label") and has?(properties, "value")) or
      Enum.any?(combinators(schema), &label_value?/1)
  end

  defp label_value?(_schema), do: false

  @doc false
  @spec find_enum(term()) :: list() | nil
  def find_enum(schema) when is_map(schema) do
    case KeyOrder.get(schema, "enum") do
      values when is_list(values) -> values
      _none -> Enum.find_value(combinators(schema), &find_enum/1)
    end
  end

  def find_enum(_schema), do: nil

  @doc false
  @spec pairs(term()) :: [{String.t(), term()}]
  def pairs(%Jason.OrderedObject{values: values}), do: values
  def pairs(%{} = map), do: Map.to_list(map)
  def pairs(_other), do: []

  defp has?(node, key), do: is_map(node) and KeyOrder.has_key?(node, key)

  defp query(document, "#/" <> pointer) do
    pointer
    |> String.split("/")
    |> Enum.reduce_while(document, fn token, node ->
      token = token |> String.replace("~1", "/") |> String.replace("~0", "~")

      if has?(node, token),
        do: {:cont, KeyOrder.get(node, token)},
        else: {:halt, nil}
    end)
  end
end

defmodule A2UICore.Catalog.Document do
  @moduledoc """
  Reads a catalog document into the parts of an `A2UICore.Catalog`
  (`parse/2`) and writes those parts back as a document (`build/1`), so
  that `build(parse(document))` equals `document`, apart from the
  components and functions that `$defs.anyComponent` /
  `$defs.anyFunction` leave out.

  Each component and function keeps its definition as written; the
  top-level fields (`$schema`, `$id`, `title`, `description`,
  `protocolVersion`, `instructions`, the theme and where it sits, the
  form of `functions`, the unions, unknown keys) are kept beside them.

  A document read as a `Jason.OrderedObject` is kept too, and the
  document written back follows its key order.
  """

  alias A2UICore.Catalog.{Component, Function, Refs, ValidationSchema}
  alias A2UICore.{Error, Identifier, KeyOrder, SemVer}

  @moduledoc since: "0.1.0"

  @default_protocol_version "0.9"
  @union_defs ["anyComponent", "anyFunction"]
  @union_order %Jason.OrderedObject{values: [{"oneOf", nil}, {"discriminator", nil}]}
  @metadata_keys ["$schema", "$id", "title", "description"]
  @modeled_keys @metadata_keys ++
                  ~w(catalogId protocolVersion instructions components functions theme $defs)

  @doc """
  Reads a catalog document (a map, or a `Jason.OrderedObject` decoded
  with `objects: :ordered_objects`, whose key order then orders the
  components and functions). Options: `:catalog_id`,
  `:protocol_version`.
  """
  @spec parse(map() | Jason.OrderedObject.t(), keyword()) :: {:ok, map()} | {:error, Error.t()}
  def parse(document, options) do
    {document, order} = plain(document)
    catalog_id = options[:catalog_id] || document["catalogId"]

    if is_binary(catalog_id) and catalog_id != "" do
      read(document, order, catalog_id, options)
    else
      {:error, catalog_error("catalog_id must be provided or exist in catalog schema.")}
    end
  end

  defp read(document, order, catalog_id, options) do
    declared = if is_binary(document["protocolVersion"]), do: document["protocolVersion"]
    version = options[:protocol_version] || declared || @default_protocol_version
    raw_defs = document["$defs"]
    defs = if is_map(raw_defs), do: raw_defs, else: %{}

    with {:ok, components} <- components(document, order, defs, version),
         {:ok, functions} <- functions(document, order, defs, catalog_id, version) do
      {theme_location, theme, defs} = theme(document, defs)
      {union_defs, null_unions, defs} = unions(defs, components, functions)

      {:ok,
       %{
         catalog_id: catalog_id,
         protocol_version: version,
         components: components,
         functions: functions,
         theme: theme,
         instructions: string(document["instructions"]),
         defs: defs,
         schema_dialect: string(document["$schema"]),
         schema_id: string(document["$id"]),
         title: string(document["title"]),
         description: string(document["description"]),
         declared_protocol_version: declared,
         declares_catalog_id: Map.has_key?(document, "catalogId"),
         declares_components: Map.has_key?(document, "components"),
         theme_location: theme_location,
         functions_form: functions_form(document),
         union_defs: union_defs,
         extras: extras(document, declared, theme_location, raw_defs),
         layout: %{
           declares_defs: is_map(raw_defs),
           null_unions: null_unions,
           theme_from_document: theme_location != nil,
           defs_from_document: true
         },
         document_order: order.document
       }}
    end
  end

  # -- ordered input ------------------------------------------------------------------

  defp plain(%Jason.OrderedObject{values: values} = document) do
    order = %{
      components: ordered_keys(List.keyfind(values, "components", 0)),
      functions: ordered_keys(List.keyfind(values, "functions", 0)),
      document: document
    }

    {to_plain(document), order}
  end

  defp plain(%{} = document),
    do: {to_plain(document), %{components: nil, functions: nil, document: nil}}

  defp ordered_keys({_key, %Jason.OrderedObject{values: values}}),
    do: Enum.map(values, &elem(&1, 0))

  defp ordered_keys(_entry), do: nil

  @doc """
  Converts `Jason.OrderedObject`s in `term` to maps.
  """
  @spec to_plain(term()) :: term()
  def to_plain(term), do: KeyOrder.to_plain(term)

  # -- components --------------------------------------------------------------------

  defp components(document, order, defs, version) do
    case Map.get(document, "components", %{}) do
      %{} = map ->
        names = order.components || Enum.sort(Map.keys(map))
        permitted = union_members(defs["anyComponent"], "#/components/")
        load_components(names, map, permitted, SemVer.at_least(version, "v1.0"))

      _other ->
        {:error,
         catalog_error("Catalog 'components' must be an object mapping names to schemas.")}
    end
  end

  defp load_components(names, map, permitted, check?),
    do: load_entries(names, permitted, &load_component(&1, map[&1], check?))

  defp load_component(name, schema, check?) do
    with :ok <- check_component_schema(name, schema),
         :ok <- if(check?, do: check_component_names(name, schema), else: :ok),
         do: {:ok, name, Component.from_schema(name, schema, from_document: true)}
  end

  # Loads each item in order and keeps the entries whose names `permitted`
  # lists (all of them when it lists none). The first item that fails to
  # load fails the catalog.
  defp load_entries(items, permitted, load) do
    items
    |> Enum.reduce_while({:ok, []}, fn item, {:ok, acc} ->
      case load.(item) do
        {:ok, name, entry} -> {:cont, {:ok, keep_permitted(acc, name, entry, permitted)}}
        error -> {:halt, error}
      end
    end)
    |> reverse_ok()
  end

  defp keep_permitted(acc, name, entry, permitted),
    do: if(permitted == [] or name in permitted, do: [entry | acc], else: acc)

  defp check_component_schema(_name, %{}), do: :ok

  defp check_component_schema(name, schema) do
    {:error,
     catalog_error(
       "Component '#{name}' schema must be a JSON schema object, got #{type_name(schema)}."
     )}
  end

  defp check_component_names(name, schema) do
    cond do
      not Identifier.valid?(name) ->
        {:error, catalog_error("Invalid UAX #31 component identifier: '#{name}'")}

      property = invalid_property(schema) ->
        {:error,
         catalog_error(
           "Invalid UAX #31 property identifier: '#{property}' in component '#{name}'"
         )}

      true ->
        :ok
    end
  end

  defp invalid_property(%{"properties" => %{} = properties}),
    do: properties |> Map.keys() |> Enum.sort() |> Enum.find(&(not Identifier.valid?(&1)))

  defp invalid_property(_schema), do: nil

  # -- functions ---------------------------------------------------------------------

  defp functions(document, order, defs, catalog_id, version) do
    with {:ok, entries} <- function_entries(document["functions"], order.functions, catalog_id) do
      permitted = union_members(defs["anyFunction"], "#/functions/")
      check? = SemVer.at_least(version, "v1.0")

      load_entries(entries, permitted, &load_function(&1, check?))
    end
  end

  defp load_function({name, spec}, check?) do
    with :ok <- if(check?, do: check_function_names(name, spec), else: :ok),
         do: {:ok, name, Function.from_schema(name, spec, from_document: true)}
  end

  defp function_entries(nil, _order, _catalog_id), do: {:ok, []}

  defp function_entries(%{} = map, order, catalog_id) do
    names = order || Enum.sort(Map.keys(map))

    Enum.reduce_while(names, {:ok, []}, fn name, {:ok, acc} ->
      case map[name] do
        %{} = spec ->
          {:cont, {:ok, [{name, spec} | acc]}}

        other ->
          {:halt,
           {:error,
            catalog_error(
              "Catalog '#{catalog_id}' function '#{name}' must be a JSON schema object, " <>
                "got #{type_name(other)}."
            )}}
      end
    end)
    |> reverse_ok()
  end

  defp function_entries(list, _order, catalog_id) when is_list(list) do
    list
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, [], MapSet.new()}, &list_entry(&1, &2, catalog_id))
    |> case do
      {:ok, entries, _seen} -> {:ok, Enum.reverse(entries)}
      error -> error
    end
  end

  defp function_entries(other, _order, catalog_id) do
    {:error,
     catalog_error(
       "Catalog '#{catalog_id}' 'functions' must be an object or a list of definitions, " <>
         "got #{type_name(other)}."
     )}
  end

  defp list_entry({%{"name" => name} = entry, index}, {:ok, acc, seen}, catalog_id)
       when is_binary(name) and name != "" do
    if MapSet.member?(seen, name) do
      {:halt,
       {:error,
        catalog_error(
          "Catalog '#{catalog_id}' function definition #{index} duplicates the name '#{name}'."
        )}}
    else
      {:cont, {:ok, [{name, Map.delete(entry, "name")} | acc], MapSet.put(seen, name)}}
    end
  end

  defp list_entry({%{}, index}, _acc, catalog_id) do
    {:halt,
     {:error,
      catalog_error(
        "Catalog '#{catalog_id}' function definition #{index} is missing a non-empty " <>
          "'name' string."
      )}}
  end

  defp list_entry({entry, index}, _acc, catalog_id) do
    {:halt,
     {:error,
      catalog_error(
        "Catalog '#{catalog_id}' function definition #{index} must be an object, " <>
          "got #{type_name(entry)}."
      )}}
  end

  defp check_function_names(name, spec) do
    cond do
      not Identifier.valid?(name) ->
        {:error, catalog_error("Invalid UAX #31 function identifier: '#{name}'")}

      argument = spec |> parameter_names() |> Enum.find(&(not Identifier.valid?(&1))) ->
        {:error,
         catalog_error("Invalid UAX #31 argument identifier: '#{argument}' in function '#{name}'")}

      true ->
        :ok
    end
  end

  # The argument names a function entry declares: those of its `args`
  # (or `parameters`) schema, or, for a bare argument schema, its own.
  defp parameter_names(spec) do
    properties = if is_map(spec["properties"]), do: spec["properties"]

    cond do
      is_map(properties) and is_map(properties["args"]) -> schema_parameters(properties["args"])
      is_map(spec["args"]) -> schema_parameters(spec["args"])
      is_map(spec["parameters"]) -> schema_parameters(spec["parameters"])
      bare_arguments?(properties) -> schema_parameters(spec)
      true -> []
    end
  end

  defp bare_arguments?(nil), do: false

  defp bare_arguments?(properties),
    do: not Enum.any?(["call", "@call", "function"], &Map.has_key?(properties, &1))

  defp schema_parameters(schema) do
    cond do
      is_map(schema["properties"]) or is_list(schema["allOf"]) -> property_names(schema)
      shorthand?(schema) -> schema |> Map.keys() |> Enum.map(&to_string/1)
      true -> []
    end
  end

  defp property_names(%{} = schema) do
    own = if is_map(schema["properties"]), do: Map.keys(schema["properties"]), else: []

    nested =
      if is_list(schema["allOf"]), do: Enum.flat_map(schema["allOf"], &property_names/1), else: []

    own ++ nested
  end

  defp property_names(_schema), do: []

  # An object whose values are property subschemas (a parameter map).
  defp shorthand?(schema) do
    schema != %{} and not is_binary(schema["type"]) and
      not Enum.any?(["$ref", "allOf", "oneOf", "anyOf", "not"], &Map.has_key?(schema, &1)) and
      Enum.all?(schema, fn {_key, value} -> is_map(value) or is_boolean(value) end)
  end

  # -- theme, unions, extras ---------------------------------------------------------

  defp theme(document, defs) do
    styles = document["styles"]

    cond do
      is_map(document["theme"]) ->
        {"theme", document["theme"], defs}

      is_map(styles) and styles != %{} and not object_schema?(styles) ->
        {"styles", %{"type" => "object", "properties" => styles}, defs}

      is_map(defs["theme"]) ->
        {"$defs", defs["theme"], Map.delete(defs, "theme")}

      true ->
        {nil, %{}, defs}
    end
  end

  defp object_schema?(node),
    do:
      Map.has_key?(node, "properties") or Map.has_key?(node, "allOf") or node["type"] == "object"

  defp unions(defs, components, functions) do
    derived = %{
      "anyComponent" => ValidationSchema.component_union(Enum.map(components, & &1.name)),
      "anyFunction" => ValidationSchema.function_union(Enum.map(functions, & &1.name))
    }

    Enum.reduce(@union_defs, {%{}, [], defs}, fn name, {_unions, _nulls, defs} = acc ->
      case defs do
        %{^name => authored} -> take_union(acc, name, authored, derived[name])
        _other -> acc
      end
    end)
  end

  # An authored union equal to the derived one is recorded as `nil`, so a
  # copy of the catalog derives it again from its own entries.
  defp take_union({unions, nulls, defs}, name, authored, derived) do
    union = if authored == derived, do: nil, else: authored
    nulls = if is_nil(authored), do: [name | nulls], else: nulls
    {Map.put(unions, name, union), nulls, Map.delete(defs, name)}
  end

  defp extras(document, declared, theme_location, raw_defs) do
    document
    |> Enum.filter(fn {key, value} -> extra?(key, value, declared, theme_location, raw_defs) end)
    |> Map.new()
    |> then(fn extras ->
      if theme_location == "styles", do: Map.delete(extras, "styles"), else: extras
    end)
  end

  defp extra?(key, value, declared, theme_location, raw_defs),
    do: key not in @modeled_keys or unmodeled?(key, value, declared, theme_location, raw_defs)

  # A modeled key whose value the model does not hold.
  defp unmodeled?(key, value, _declared, _theme_location, _raw_defs)
       when key in ["instructions" | @metadata_keys],
       do: not is_binary(value)

  defp unmodeled?("protocolVersion", _value, declared, _theme_location, _raw_defs),
    do: is_nil(declared)

  defp unmodeled?("theme", _value, _declared, theme_location, _raw_defs),
    do: theme_location != "theme"

  defp unmodeled?("$defs", _value, _declared, _theme_location, raw_defs), do: not is_map(raw_defs)
  defp unmodeled?(_key, _value, _declared, _theme_location, _raw_defs), do: false

  defp functions_form(%{"functions" => list}) when is_list(list), do: :list
  defp functions_form(%{"functions" => _}), do: :map
  defp functions_form(_document), do: nil

  defp union_members(%{"oneOf" => members}, prefix) when is_list(members) do
    for %{"$ref" => ref} <- members, is_binary(ref), String.starts_with?(ref, prefix) do
      ref |> String.split("/") |> List.last()
    end
  end

  defp union_members(_union, _prefix), do: []

  # -- writing -----------------------------------------------------------------------

  @doc """
  Writes a catalog's parts back as its document (`A2UICore.Catalog.to_json/2`),
  as ordered objects: the top-level fields in a fixed order (`$schema`,
  `$id`, `protocolVersion`, `title`, `description`, `catalogId`,
  `instructions`, unknown keys, `components`, `functions`, the theme,
  `$defs`), and what was read from a document in that document's order.
  """
  @spec build(A2UICore.Catalog.t()) :: Jason.OrderedObject.t()
  def build(catalog) do
    system = ValidationSchema.system_names(catalog.protocol_version)

    common =
      MapSet.difference(ValidationSchema.common_names(), MapSet.new(Map.keys(catalog.defs)))

    uri = catalog.common_types_uri
    source = catalog.document_order

    components = Enum.map(catalog.component_order, &catalog.components[&1])

    functions =
      catalog.function_order
      |> Enum.map(&catalog.functions[&1])
      |> Enum.filter(
        &(&1.from_document or not (&1.name in system or String.starts_with?(&1.name, "@")))
      )

    component_docs =
      Enum.map(components, fn component ->
        template = KeyOrder.get(KeyOrder.get(source, "components"), component.name)
        {component.name, component_entry(component, common, uri, template)}
      end)

    function_docs =
      Enum.map(functions, fn function ->
        template = function_template(source, function.name)
        {function.name, function_entry(function, common, uri, catalog.protocol_version, template)}
      end)

    KeyOrder.new()
    |> put_some("$schema", catalog.schema_dialect)
    |> put_some("$id", catalog.schema_id)
    |> put_some("protocolVersion", catalog.declared_protocol_version)
    |> put_some("title", catalog.title)
    |> put_some("description", catalog.description)
    |> put_catalog_id(catalog)
    |> put_some("instructions", catalog.instructions)
    |> put_extras(catalog.extras, source)
    |> put_components(component_docs, catalog.declares_components)
    |> put_functions(function_docs, catalog.functions_form)
    |> put_theme(catalog, common)
    |> put_defs(catalog, common, Enum.map(components, & &1.name), Enum.map(functions, & &1.name))
  end

  defp function_template(source, name) do
    case KeyOrder.get(source, "functions") do
      list when is_list(list) -> Enum.find(list, &(KeyOrder.get(&1, "name") == name))
      functions -> KeyOrder.get(functions, name)
    end
  end

  defp put_some(object, _key, nil), do: object
  defp put_some(object, key, value), do: KeyOrder.put(object, key, value)

  defp put_catalog_id(object, %{declares_catalog_id: true, catalog_id: id}),
    do: KeyOrder.put(object, "catalogId", id)

  defp put_catalog_id(object, _catalog), do: object

  # Unknown keys, in the order of the document they were read from.
  defp put_extras(object, extras, source) do
    %Jason.OrderedObject{values: pairs} = KeyOrder.like(extras, source)
    Enum.reduce(pairs, object, fn {key, value}, acc -> KeyOrder.put(acc, key, value) end)
  end

  defp put_components(object, docs, declares?) do
    if docs != [] or declares?,
      do: KeyOrder.put(object, "components", KeyOrder.new(docs)),
      else: object
  end

  defp put_functions(object, [], nil), do: object

  defp put_functions(object, docs, :list),
    do: KeyOrder.put(object, "functions", Enum.map(docs, &list_form/1))

  defp put_functions(object, docs, _form),
    do: KeyOrder.put(object, "functions", KeyOrder.new(docs))

  defp list_form({name, %Jason.OrderedObject{values: values}}),
    do: KeyOrder.new([{"name", name} | values])

  defp component_entry(component, common, uri, template) do
    entry =
      if component.from_document,
        do: KeyOrder.like(component.schema, template),
        else: KeyOrder.like(Refs.externalize(component.schema, common, uri), nil)

    entry
    |> allowed("allowedParents", component.allowed_parents)
    |> allowed("allowedChildren", component.allowed_children)
  end

  defp allowed(entry, key, nil) do
    if KeyOrder.get(entry, key) == nil, do: entry, else: KeyOrder.delete(entry, key)
  end

  defp allowed(entry, key, value), do: KeyOrder.put(entry, key, value)

  defp function_entry(function, common, uri, version, template) do
    if Function.definition?(function),
      do: definition_entry(function, common, uri, template),
      else: call_document(function, Refs.externalize(function.schema, common, uri), version)
  end

  defp definition_entry(function, common, uri, template) do
    entry =
      if function.from_document,
        do: KeyOrder.like(function.schema, template),
        else: KeyOrder.like(Refs.externalize(function.schema, common, uri), nil)

    written_callers = KeyOrder.get(entry, "allowedCallers") || "rendererOnly"
    written_activation = KeyOrder.get(entry, "requiresUserActivation") not in [nil, false, 0, ""]

    entry =
      if is_nil(function.description),
        do: entry,
        else: KeyOrder.put(entry, "description", function.description)

    entry
    |> put_return_type(function.return_type || "any")
    |> put_differing(
      "allowedCallers",
      function.allowed_callers || "rendererOnly",
      written_callers
    )
    |> put_differing(
      "requiresUserActivation",
      function.requires_user_activation == true,
      written_activation
    )
  end

  defp put_return_type(entry, return_type) do
    if return_type == (Function.declared_return_type(to_plain(entry)) || "any") do
      entry
    else
      properties = KeyOrder.get(entry, "properties")
      call = KeyOrder.get(properties, "returnType")

      if not KeyOrder.has_key?(entry, "returnType") and match?(%Jason.OrderedObject{}, call) and
           KeyOrder.has_key?(call, "const") do
        call = KeyOrder.put(call, "const", return_type)
        KeyOrder.put(entry, "properties", KeyOrder.put(properties, "returnType", call))
      else
        KeyOrder.put(entry, "returnType", return_type)
      end
    end
  end

  defp put_differing(entry, _key, same, same), do: entry
  defp put_differing(entry, key, value, _written), do: KeyOrder.put(entry, key, value)

  # A function defined in code by its `args` schema, in the call shape of
  # its protocol version.
  defp call_document(function, args, version) do
    args = args |> KeyOrder.like(nil) |> KeyOrder.put_new("type", "object")
    return_type = function.return_type || "any"

    document =
      if SemVer.at_least(version, "v1.0") do
        KeyOrder.new([
          {"type", "object"},
          {"properties",
           KeyOrder.new([{"@call", KeyOrder.new([{"const", function.name}])}, {"args", args}])},
          {"required", ["@call", "args"]}
        ])
      else
        KeyOrder.new([
          {"type", "object"},
          {"properties",
           KeyOrder.new([
             {"call", KeyOrder.new([{"const", function.name}])},
             {"args", args},
             {"returnType", KeyOrder.new([{"const", return_type}])}
           ])},
          {"required", ["call", "args"]},
          {"unevaluatedProperties", false}
        ])
      end

    document = put_some(document, "description", function.description)

    if SemVer.at_least(version, "v1.0") do
      document
      |> KeyOrder.put_new("returnType", return_type)
      |> put_unless("allowedCallers", function.allowed_callers, &(&1 in [nil, "rendererOnly"]))
      |> put_unless("requiresUserActivation", function.requires_user_activation, &(&1 != true))
    else
      document
    end
  end

  defp put_unless(object, key, value, skip?),
    do: if(skip?.(value), do: object, else: KeyOrder.put_new(object, key, value))

  defp put_theme(object, catalog, common) do
    case theme_document(catalog, common) do
      nil ->
        object

      theme when catalog.theme_location == "theme" ->
        KeyOrder.put(object, "theme", theme)

      theme when catalog.theme_location == "styles" ->
        KeyOrder.put(object, "styles", styles(theme))

      _theme ->
        object
    end
  end

  defp styles(theme) do
    case KeyOrder.get(theme, "properties") do
      %Jason.OrderedObject{} = properties -> properties
      _other -> theme
    end
  end

  defp theme_document(%{theme_location: nil}, _common), do: nil

  defp theme_document(catalog, common) do
    cond do
      catalog.theme == %{} and catalog.theme_location not in ["theme", "$defs"] ->
        nil

      catalog.layout.theme_from_document ->
        KeyOrder.like(catalog.theme, theme_template(catalog))

      true ->
        KeyOrder.like(Refs.externalize(catalog.theme, common, catalog.common_types_uri), nil)
    end
  end

  defp theme_template(%{document_order: source, theme_location: "theme"}),
    do: KeyOrder.get(source, "theme")

  defp theme_template(%{document_order: source, theme_location: "$defs"}),
    do: KeyOrder.get(KeyOrder.get(source, "$defs"), "theme")

  defp theme_template(%{document_order: source, theme_location: "styles"}),
    do: KeyOrder.new([{"type", "object"}, {"properties", KeyOrder.get(source, "styles")}])

  defp put_defs(object, catalog, common, component_names, function_names) do
    template = KeyOrder.get(catalog.document_order, "$defs")

    own =
      for {name, schema} <- catalog.defs, name not in @union_defs, into: %{} do
        if catalog.layout.defs_from_document,
          do: {name, schema},
          else: {name, Refs.externalize(schema, common, catalog.common_types_uri)}
      end

    defs = KeyOrder.like(own, template)

    defs =
      case theme_document(catalog, common) do
        nil ->
          defs

        theme ->
          if catalog.theme_location == "$defs", do: KeyOrder.put(defs, "theme", theme), else: defs
      end

    defs =
      catalog
      |> union_documents(component_names, function_names)
      |> Enum.reduce(defs, fn {name, union}, acc ->
        KeyOrder.put(acc, name, KeyOrder.like(union, KeyOrder.get(template, name)))
      end)

    if not KeyOrder.empty?(defs) or catalog.layout.declares_defs,
      do: KeyOrder.put(object, "$defs", defs),
      else: object
  end

  defp union_documents(%{union_defs: nil} = catalog, component_names, function_names) do
    v1? = SemVer.at_least(catalog.protocol_version, "v1.0")

    Enum.filter(
      [
        {"anyComponent", component_names != [] or v1?, &component_union/1, component_names},
        {"anyFunction", function_names != [] or v1?, &function_union/1, function_names}
      ],
      &elem(&1, 1)
    )
    |> Enum.map(fn {name, _write?, union, names} -> {name, union.(names)} end)
  end

  defp union_documents(catalog, component_names, function_names) do
    for name <- @union_defs, Map.has_key?(catalog.union_defs, name) do
      schema = catalog.union_defs[name]

      cond do
        schema != nil or name in catalog.layout.null_unions -> {name, schema}
        name == "anyComponent" -> {name, component_union(component_names)}
        true -> {name, function_union(function_names)}
      end
    end
  end

  # The derived unions, in the order the reference writes their keys.
  defp component_union(names),
    do: KeyOrder.like(ValidationSchema.component_union(names), @union_order)

  defp function_union(names),
    do: KeyOrder.like(ValidationSchema.function_union(names), @union_order)

  # -- helpers -----------------------------------------------------------------------

  defp reverse_ok({:ok, list}), do: {:ok, Enum.reverse(list)}
  defp reverse_ok(error), do: error

  defp string(value) when is_binary(value), do: value
  defp string(_value), do: nil

  defp catalog_error(message), do: Error.new(:catalog, "CATALOG_ERROR", message)

  defp type_name(value) when is_list(value), do: "list"
  defp type_name(value) when is_binary(value), do: "str"
  defp type_name(value) when is_integer(value), do: "int"
  defp type_name(value) when is_float(value), do: "float"
  defp type_name(value) when is_boolean(value), do: "bool"
  defp type_name(nil), do: "NoneType"
  defp type_name(_value), do: "object"
end

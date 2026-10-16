defmodule A2UICore.Catalog.ValidationSchema do
  @moduledoc """
  Builds a catalog's validation schema: the self-contained JSON Schema
  messages are validated against (the reference's
  `Catalog.validation_schema`).

  From the catalog's resolved schemas (references into its own `$defs`
  and peers written inline, references to common types kept):

    1. the components, functions, own `$defs` and theme are assembled,
       with `anyComponent` / `anyFunction` listing the entries, and
       cleaned (`A2UICore.Catalog.SchemaCleaner`);
    2. each component is flattened: its `allOf` mixins (`ComponentCommon`,
       `Checkable`, local `$defs` mixins) are merged into one
       `properties` / `required` object, its own properties winning,
       inside the canonical envelope (`id`, `component`); local mixins
       nothing references any more leave `$defs`;
    3. a `$ref` to a common type without a `description` takes the
       type's description;
    4. the common types the schema references, transitively, are bundled
       into `$defs` from the published `common_types.json` (a catalog
       without functions gets `anyFunction: {"not": {}}`);
    5. the declared `protocolVersion` is written in its bare form, and
       before v1.0 every function call schema is closed.
  """

  alias A2UICore.Catalog.{Refs, SchemaCleaner}
  alias A2UICore.Schema.Source
  alias A2UICore.{SemVer, Version}

  @moduledoc since: "0.1.0"

  @dialect "https://json-schema.org/draft/2020-12/schema"
  @union_defs ["anyComponent", "anyFunction"]
  @standard_mixins ["ComponentCommon", "Checkable"]
  @envelope_keys ["id", "component", "catalogId"]
  @merged_keys ~w(type description allOf properties required unevaluatedProperties
                  additionalProperties allowedParents allowedChildren)

  @typedoc """
  What the build needs from a catalog.
  """
  @type input :: %{
          required(:catalog_id) => String.t(),
          required(:protocol_version) => String.t(),
          required(:instructions) => String.t() | nil,
          required(:declared_protocol_version) => String.t() | nil,
          required(:defs) => map(),
          required(:components) => map(),
          required(:functions) => map(),
          required(:resolved) => map(),
          required(:component_order) => [String.t()],
          required(:function_order) => [String.t()],
          optional(atom()) => term()
        }

  @doc """
  The validation schema of a catalog.
  """
  @spec build(input()) :: map()
  def build(catalog) do
    version = catalog.protocol_version
    v1? = SemVer.at_least(version, "v1.0")
    published = published_defs(version)
    {schema, referenced} = SchemaCleaner.clean(assemble(catalog), dynamic_index(version))

    schema =
      schema
      |> flatten(catalog, published, v1?)
      |> propagate_descriptions(published)

    seeds =
      referenced
      |> MapSet.difference(MapSet.new(@standard_mixins))
      |> MapSet.union(Refs.def_refs(schema))

    schema
    |> bundle(seeds, published, catalog.defs)
    |> finish(catalog, v1?)
  end

  @doc """
  The names of the system functions a protocol version supplies to every
  catalog (`@index` from v1.0 on).
  """
  @spec system_names(String.t()) :: [String.t()]
  def system_names(version), do: if(SemVer.at_least(version, "v1.0"), do: ["@index"], else: [])

  @doc """
  The published common types `$defs` of a protocol version, with
  cross-document references made local. Empty for an unsupported
  version.
  """
  @spec published_defs(String.t()) :: map()
  def published_defs(version) do
    cached({:published, version}, fn ->
      with {:ok, canonical} <- Version.to_protocol_version(version),
           %{"$defs" => defs} <- Source.document(canonical, :common_types) do
        Refs.normalize(defs)
      else
        _other -> %{}
      end
    end)
  end

  @doc """
  The names of the common types of every supported protocol version:
  the references a catalog keeps when it writes its own references
  inline.
  """
  @spec common_names() :: MapSet.t(String.t())
  def common_names do
    cached(:common_names, fn ->
      Version.supported()
      |> Enum.flat_map(&Map.keys(published_defs(&1)))
      |> MapSet.new()
    end)
  end

  defp dynamic_index(version),
    do: cached({:index, version}, fn -> SchemaCleaner.index(published_defs(version)) end)

  defp cached(key, fun) do
    key = {__MODULE__, key}

    case :persistent_term.get(key, :missing) do
      :missing ->
        value = fun.()
        :persistent_term.put(key, value)
        value

      value ->
        value
    end
  end

  # -- assembly -------------------------------------------------------------------

  defp assemble(catalog) do
    resolved = catalog.resolved
    system = system_names(catalog.protocol_version)
    functions = Enum.reject(catalog.function_order, &(&1 in system))
    components = catalog.component_order

    defs =
      resolved.defs
      |> put_theme(resolved.theme, catalog.protocol_version)
      |> merge_entry_defs(components, resolved.components)
      |> merge_entry_defs(functions, resolved.functions)
      |> put_union("anyComponent", components, &component_union/1)
      |> put_union("anyFunction", functions, &function_union/1)

    %{"$schema" => @dialect, "catalogId" => catalog.catalog_id}
    |> put_if("instructions", catalog.instructions, &(is_binary(&1) and &1 != ""))
    |> put_if(
      "components",
      entry_schemas(components, resolved.components, &component_schema/2),
      &(&1 != %{})
    )
    |> put_if(
      "functions",
      entry_schemas(functions, resolved.functions, &function_schema/2),
      &(&1 != %{})
    )
    |> put_if("$defs", defs, &(&1 != %{}))
  end

  defp put_theme(defs, theme, version) when is_map(theme) and map_size(theme) > 0,
    do: Map.put(defs, "theme", open_theme(theme, version))

  defp put_theme(defs, _theme, _version), do: defs

  # From v0.9 a theme that decides nothing about unlisted properties says
  # it is open, so renderers may add their own.
  defp open_theme(theme, version) do
    object? = theme["type"] == "object" or Map.has_key?(theme, "properties")

    closed? =
      Enum.any?(
        ["additionalProperties", "unevaluatedProperties", "$ref"],
        &Map.has_key?(theme, &1)
      )

    if SemVer.at_least(version, "v0.9") and object? and not closed?,
      do: Map.put(theme, "additionalProperties", true),
      else: theme
  end

  defp merge_entry_defs(defs, names, schemas) do
    Enum.reduce(names, defs, fn name, acc ->
      case schemas[name] do
        %{"$defs" => entry_defs} when is_map(entry_defs) -> Map.merge(entry_defs, acc)
        _other -> acc
      end
    end)
  end

  defp put_union(defs, _key, [], _union), do: defs
  defp put_union(defs, key, names, union), do: Map.put(defs, key, union.(names))

  @doc """
  The `anyComponent` union of `names`: `{"not": {}}` when there are
  none.
  """
  @spec component_union([String.t()]) :: map()
  def component_union([]), do: %{"not" => %{}}

  def component_union(names) do
    %{
      "oneOf" => Enum.map(names, &%{"$ref" => "#/components/" <> &1}),
      "discriminator" => %{"propertyName" => "component"}
    }
  end

  @doc """
  The `anyFunction` union of `names`: `{"not": {}}` when there are none.
  """
  @spec function_union([String.t()]) :: map()
  def function_union([]), do: %{"not" => %{}}
  def function_union(names), do: %{"oneOf" => Enum.map(names, &%{"$ref" => "#/functions/" <> &1})}

  defp entry_schemas(names, schemas, shape) do
    for name <- names,
        Map.has_key?(schemas, name),
        into: %{},
        do: {name, shape.(name, schemas[name])}
  end

  defp component_schema(name, %{} = schema) do
    schema
    |> SchemaCleaner.mark_titles()
    |> Map.delete("$defs")
    |> component_const(name)
    |> unevaluated()
  end

  defp component_schema(_name, schema), do: schema

  defp component_const(%{"properties" => %{"component" => property} = properties} = schema, name) do
    const =
      case property do
        %{"const" => const} -> const
        _other -> name
      end

    required = if is_list(schema["required"]), do: schema["required"], else: []
    required = if "component" in required, do: required, else: required ++ ["component"]

    %{schema | "properties" => %{properties | "component" => %{"const" => const}}}
    |> Map.put("required", required)
  end

  defp component_const(schema, _name), do: schema

  defp unevaluated(%{"unevaluatedProperties" => _} = schema), do: schema

  defp unevaluated(%{"additionalProperties" => value} = schema),
    do: schema |> Map.delete("additionalProperties") |> Map.put("unevaluatedProperties", value)

  defp unevaluated(schema), do: schema

  defp function_schema(_name, %{} = schema),
    do: schema |> SchemaCleaner.mark_titles() |> Map.delete("$defs")

  defp function_schema(_name, schema), do: schema

  # -- flattening -------------------------------------------------------------------

  defp flatten(%{"components" => components} = schema, catalog, standard, v1?)
       when is_map(components) do
    local_defs = schema["$defs"] || %{}

    {components, used} =
      Enum.reduce(components, {%{}, MapSet.new()}, fn {name, component_schema}, {acc, used} ->
        authored = authored_schema(catalog, name)
        used = local_mixin_refs(authored, local_defs, used)

        {flat, used} =
          flatten_component(name, component_schema, catalog, local_defs, standard, used, v1?)

        {Map.put(acc, name, flat), used}
      end)

    schema
    |> Map.put("components", components)
    |> prune_local_mixins(local_defs, used)
  end

  defp flatten(schema, _catalog, _standard, _v1?), do: schema

  defp authored_schema(catalog, name) do
    case catalog.components[name] do
      %{schema: %{} = schema} -> schema
      _other -> nil
    end
  end

  defp flatten_component(name, %{} = schema, catalog, local_defs, standard, used, v1?) do
    state = %{visited: MapSet.new(), used: used, unmerged: []}
    {groups, state} = collect(schema, local_defs, standard, state)
    pieces = groups.mixins ++ groups.local ++ groups.common ++ groups.specific

    flat =
      %{"type" => "object"}
      |> Map.merge(Map.drop(schema, @merged_keys))
      |> put_if("description", piece_description(pieces), &is_binary/1)
      |> Map.put("properties", piece_properties(pieces, name))
      |> Map.put("required", ["id"] ++ Enum.sort(piece_required(pieces)) ++ ["component"])
      |> put_if("allOf", state.unmerged, &(&1 != []))
      |> put_closure(schema, v1?)
      |> put_allowed("allowedParents", schema, catalog.components[name])
      |> put_allowed("allowedChildren", schema, catalog.components[name])

    {flat, state.used}
  end

  defp flatten_component(_name, schema, _catalog, _local_defs, _standard, used, _v1?),
    do: {schema, used}

  defp piece_description(pieces) do
    Enum.reduce(pieces, nil, fn
      %{"description" => description}, _acc when is_binary(description) and description != "" ->
        description

      _piece, acc ->
        acc
    end)
  end

  defp piece_properties(pieces, name) do
    {properties, const} =
      Enum.reduce(pieces, {%{}, name}, fn piece, {props, const} ->
        case piece["properties"] do
          %{} = own ->
            {Map.merge(props, Map.drop(own, @envelope_keys)), component_const_of(own, const)}

          _other ->
            {props, const}
        end
      end)

    properties
    |> Map.put("id", %{"$ref" => "#/$defs/ComponentId"})
    |> Map.put("component", %{"const" => const})
  end

  defp component_const_of(%{"component" => %{"const" => const}}, _default) when is_binary(const),
    do: const

  defp component_const_of(_properties, default), do: default

  defp piece_required(pieces) do
    pieces
    |> Enum.flat_map(fn piece ->
      if is_list(piece["required"]), do: piece["required"], else: []
    end)
    |> Enum.filter(&(is_binary(&1) and &1 not in @envelope_keys))
    |> Enum.uniq()
  end

  defp put_closure(flat, schema, v1?) do
    closure =
      if Map.has_key?(schema, "unevaluatedProperties"),
        do: schema["unevaluatedProperties"],
        else: schema["additionalProperties"]

    closure = if is_nil(closure) and not v1?, do: false, else: closure
    if is_nil(closure), do: flat, else: Map.put(flat, "unevaluatedProperties", closure)
  end

  defp put_allowed(flat, key, schema, component) do
    value =
      case schema[key] do
        list when is_list(list) and list != [] -> list
        _other -> component_allowed(component, key)
      end

    if is_list(value) and value != [], do: Map.put(flat, key, value), else: flat
  end

  defp component_allowed(%{allowed_parents: value}, "allowedParents"), do: value
  defp component_allowed(%{allowed_children: value}, "allowedChildren"), do: value
  defp component_allowed(_component, _key), do: nil

  # The `(mixins, local, common inline, specific inline)` pieces of a
  # component schema, in the reference's order.
  defp collect(schema, local_defs, standard, state) do
    empty = %{mixins: [], local: [], common: [], specific: []}

    {groups, state} =
      case schema["allOf"] do
        members when is_list(members) ->
          Enum.reduce(members, {empty, state}, &collect_member(&1, &2, local_defs, standard))

        _other ->
          {empty, state}
      end

    {own_piece(groups, schema), state}
  end

  defp own_piece(groups, schema) do
    if Enum.any?(["properties", "required", "description"], &Map.has_key?(schema, &1)) do
      case schema["properties"] do
        %{"component" => _} -> %{groups | specific: groups.specific ++ [schema]}
        _other -> %{groups | common: groups.common ++ [schema]}
      end
    else
      groups
    end
  end

  defp collect_member(%{"$ref" => ref} = member, {groups, state}, local_defs, standard)
       when is_binary(ref) do
    name = def_name(ref)

    if name != nil and name not in @standard_mixins and Map.has_key?(local_defs, name),
      do: collect_local_mixin(ref, name, groups, state, local_defs, standard),
      else: collect_standard_mixin(member, name, groups, state, standard)
  end

  defp collect_member(%{} = member, {groups, state}, local_defs, standard) do
    {sub, state} = collect(member, local_defs, standard, state)
    extra = Map.drop(member, @merged_keys)
    state = if extra == %{}, do: state, else: %{state | unmerged: state.unmerged ++ [extra]}
    {append_groups(groups, sub), state}
  end

  defp collect_member(_member, acc, _local_defs, _standard), do: acc

  defp collect_local_mixin(ref, name, groups, state, local_defs, standard) do
    state = %{state | used: MapSet.put(state.used, name)}

    case local_defs[name] do
      %{} = target ->
        if MapSet.member?(state.visited, ref) do
          {groups, state}
        else
          state = %{state | visited: MapSet.put(state.visited, ref)}
          {sub, state} = collect(target, local_defs, standard, state)

          {%{
             groups
             | mixins: groups.mixins ++ sub.mixins,
               local: groups.local ++ sub.local ++ sub.common ++ sub.specific
           }, state}
        end

      _other ->
        {groups, state}
    end
  end

  defp collect_standard_mixin(member, name, groups, state, standard) do
    case name && standard[name] do
      %{"properties" => %{} = properties} = mixin ->
        piece = %{"properties" => properties}

        piece =
          if is_list(mixin["required"]),
            do: Map.put(piece, "required", mixin["required"]),
            else: piece

        {%{groups | mixins: groups.mixins ++ [piece]}, state}

      _other ->
        {groups, %{state | unmerged: state.unmerged ++ [member]}}
    end
  end

  defp append_groups(groups, sub) do
    %{
      mixins: groups.mixins ++ sub.mixins,
      local: groups.local ++ sub.local,
      common: groups.common ++ sub.common,
      specific: groups.specific ++ sub.specific
    }
  end

  defp def_name(ref) do
    case Refs.own_def_name(ref) do
      nil -> fallback_def_name(ref)
      name -> name
    end
  end

  defp fallback_def_name(ref) do
    case String.split(ref, "#/$defs/") do
      [_ | [_ | _] = parts] -> parts |> List.last() |> String.split("/") |> hd()
      _other -> nil
    end
  end

  # The local mixins a component's authored schema composes through
  # `allOf`, transitively.
  defp local_mixin_refs(%{"allOf" => members}, local_defs, found) when is_list(members) do
    Enum.reduce(members, found, fn
      %{} = member, acc -> local_mixin_member(member, local_defs, acc)
      _other, acc -> acc
    end)
  end

  defp local_mixin_refs(_schema, _local_defs, found), do: found

  defp local_mixin_member(member, local_defs, found) do
    name = Refs.own_def_name(member["$ref"])

    if name != nil and name not in @standard_mixins and not MapSet.member?(found, name) do
      local_mixin_refs(local_defs[name], local_defs, MapSet.put(found, name))
    else
      local_mixin_refs(member, local_defs, found)
    end
  end

  defp prune_local_mixins(schema, local_defs, used) do
    if local_defs == %{} or MapSet.size(used) == 0 do
      schema
    else
      roots = [schema["components"], schema["functions"], local_defs["theme"]]
      reachable = Refs.reachable_defs(roots, local_defs)

      dropped =
        Enum.filter(used, fn name ->
          Map.has_key?(local_defs, name) and not MapSet.member?(reachable, name) and
            name not in @union_defs and name != "theme"
        end)

      Map.put(schema, "$defs", Map.drop(local_defs, dropped))
    end
  end

  # -- descriptions ------------------------------------------------------------------

  defp propagate_descriptions(schema, standard) do
    Enum.reduce(["components", "functions", "$defs"], schema, fn key, acc ->
      case acc do
        %{^key => value} -> Map.put(acc, key, propagate(value, standard))
        _other -> acc
      end
    end)
  end

  defp propagate(%{} = node, standard) do
    node =
      with %{"$ref" => "#/$defs/" <> rest} <- node,
           false <- Map.has_key?(node, "description"),
           %{"description" => description} when is_binary(description) <-
             standard[rest |> String.split("/") |> hd()] do
        Map.put(node, "description", description)
      else
        _other -> node
      end

    Map.new(node, fn {key, value} -> {key, propagate(value, standard)} end)
  end

  defp propagate(list, standard) when is_list(list), do: Enum.map(list, &propagate(&1, standard))
  defp propagate(other, _standard), do: other

  # -- common types --------------------------------------------------------------------

  defp bundle(schema, seeds, published, own_defs) do
    defs =
      (schema["$defs"] || %{})
      |> Map.reject(fn {name, _} ->
        not Map.has_key?(own_defs, name) and Map.has_key?(published, name)
      end)

    chosen = choose(Enum.sort(seeds), MapSet.new(Map.keys(defs)), published, %{})
    Map.put(schema, "$defs", Map.merge(defs, chosen))
  end

  defp choose([], _own, _published, chosen), do: chosen

  defp choose([name | rest], own, published, chosen) do
    definition =
      cond do
        MapSet.member?(own, name) or Map.has_key?(chosen, name) -> nil
        Map.has_key?(published, name) -> published[name]
        name in @union_defs -> %{"not" => %{}}
        true -> nil
      end

    case definition do
      nil ->
        choose(rest, own, published, chosen)

      definition ->
        next = definition |> Refs.def_refs() |> Enum.sort()
        choose(rest ++ next, own, published, Map.put(chosen, name, definition))
    end
  end

  # -- finishing ---------------------------------------------------------------------

  defp finish(schema, catalog, v1?) do
    schema =
      case catalog.declared_protocol_version do
        declared when is_binary(declared) ->
          Map.put(
            schema,
            "protocolVersion",
            Regex.replace(~r/^[vV](?=\d)/, String.trim(declared), "")
          )

        _other ->
          schema
      end

    case schema["functions"] do
      %{} = functions ->
        Map.put(schema, "functions", Map.new(functions, &finish_function(&1, catalog, v1?)))

      _other ->
        schema
    end
  end

  defp finish_function({name, entry}, catalog, v1?) do
    entry =
      case catalog.functions[name] do
        %{} = function when not v1? -> close_call(entry, function.return_type || "any")
        _v1_or_missing -> entry
      end

    {name, normalize_args_closure(entry)}
  end

  # Gives a pre-v1.0 call schema the specification's shape: a `returnType`
  # constant, `call` (and `args` when it requires arguments) required, and
  # no unlisted properties in the call or its `args`.
  defp close_call(%{"properties" => %{"call" => _} = properties} = entry, return_type) do
    properties = Map.put_new(properties, "returnType", %{"const" => return_type})
    entry = if closes?(entry), do: entry, else: Map.put(entry, "unevaluatedProperties", false)
    required = Map.get(entry, "required", [])

    required =
      if is_list(required) and "call" not in required, do: ["call" | required], else: required

    {properties, required} =
      case properties["args"] do
        %{} = args -> close_args(properties, args, required)
        _other -> {properties, required}
      end

    entry |> Map.put("properties", properties) |> Map.put("required", required)
  end

  defp close_call(entry, _return_type), do: entry

  defp close_args(properties, args, required) do
    args =
      if closes?(args) or Map.has_key?(args, "$ref"),
        do: args,
        else: Map.put(args, "unevaluatedProperties", false)

    required =
      if is_list(required) and truthy?(args["required"]) and "args" not in required,
        do: required ++ ["args"],
        else: required

    {Map.put(properties, "args", args), required}
  end

  defp truthy?(value), do: value not in [nil, false, [], "", 0, %{}]

  defp closes?(schema),
    do:
      Map.has_key?(schema, "additionalProperties") or
        Map.has_key?(schema, "unevaluatedProperties")

  defp normalize_args_closure(
         %{"properties" => %{"args" => %{"type" => "object"} = args} = properties} = entry
       )
       when is_map_key(properties, "call") or is_map_key(properties, "@call") do
    if Map.has_key?(args, "$ref") do
      entry
    else
      {additional, args} = Map.pop(args, "additionalProperties")

      args =
        Map.put_new(
          args,
          "unevaluatedProperties",
          if(is_nil(additional), do: false, else: additional)
        )

      %{entry | "properties" => %{properties | "args" => args}}
    end
  end

  defp normalize_args_closure(entry), do: entry

  defp put_if(map, key, value, keep?) do
    if keep?.(value), do: Map.put(map, key, value), else: map
  end
end

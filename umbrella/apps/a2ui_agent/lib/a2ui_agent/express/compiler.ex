defmodule A2UIAgent.Express.Compiler do
  @moduledoc """
  Compiles an Express block into A2UI messages.

      {:ok, catalogs} = A2UIAgent.Express.Catalogs.new([catalog])

      A2UIAgent.Express.Compiler.compile(catalogs, ~s(root = Text("Hello")), surface_id: "s1")
      #=> {:ok, [%{"version" => "v1.0", "createSurface" => %{"surfaceId" => "s1", ...}}]}

  Statements group into surfaces. `surface("id")` opens a surface (with
  `sendDataModel=` and `update=` keywords); assignments before any
  `surface` line belong to the default surface. In a surface:

    * a variable assigned a component becomes a component whose id is
      the variable's name (or its `id=` argument); a component written
      inline as an argument becomes a component with the id
      `<parent>_<property>` (`<parent>_<property>_<index>` in a list);
    * a variable assigned anything else is substituted where it is used;
    * `$/a/b = value` writes the data model.

  A surface with a `root` component becomes `createSurface` (followed by
  `updateComponents` and `updateDataModel` before v1.0); with
  `update=true`, or without a `root`, it becomes `updateComponents` and
  `updateDataModel`. `deleteSurface("id")` deletes a surface, and a
  standalone function call becomes `callRendererFunction` (v1.0) with
  the id `call_<n>` unless it has a `functionCallId=` argument.

  Positional arguments follow `A2UIAgent.Express.SchemaHelper`'s order,
  `_` skips one, and keyword arguments name a property. Check rules
  (`?name(...)`) go in the component's check property; a check whose
  first parameter is `value` receives the component's bound `value`
  unless its first argument is a path, and a trailing string argument is
  its message (default `"<Name> check failed"`). In an action property a
  function call is written as `{"functionCall": ...}`, and
  `Event(name, context)` writes an event.
  """

  alias A2UIAgent.Express.{Catalogs, Failure, SchemaHelper, Syntax}
  alias A2UICore.Error

  @moduledoc since: "0.1.0"

  @reserved_calls ~w(Event _template surface deleteSurface)

  @doc """
  Compiles `block`. Options: `:surface_id`, the surface of assignments
  before any `surface` line (default `"default_surface"`), and `:final`
  (default true). A block that is not final (its closing tag has not
  arrived) compiles the statements before its first syntax error.

  A syntax error, or a block that breaks Express's own rules, is a
  `:parse` error; a block naming what the catalogs do not define, or
  giving a value they do not admit, is a `:validation` error.
  """
  @spec compile(Catalogs.t(), String.t(), keyword()) :: {:ok, [map()]} | {:error, Error.t()}
  def compile(%Catalogs{} = catalogs, block, options \\ []) do
    {:ok, do_compile(catalogs, block, options)}
  rescue
    failure in Failure -> {:error, Failure.to_compilation_error(failure)}
  end

  defp do_compile(catalogs, block, options) do
    version = catalogs.version
    final? = Keyword.get(options, :final, true)
    surface_id = Keyword.get(options, :surface_id, "default_surface")

    statements = block |> strip_tags() |> statements(final?)
    {units, scopes} = units(catalogs, statements, surface_id)

    if units == [], do: undefined_root!()

    state = %{
      catalogs: catalogs,
      version: version,
      keys: SchemaHelper.reserved_keys(version),
      scopes: scopes
    }

    {messages, _calls} =
      Enum.flat_map_reduce(units, 0, fn unit, calls -> compile_unit(state, unit, calls) end)

    messages
  end

  # Lines outside `<a2ui>` and `</a2ui>` are dropped when the block
  # carries the tags.
  defp strip_tags(block) do
    if String.contains?(block, "<a2ui>") do
      block
      |> String.split(~r/\r?\n/)
      |> Enum.reduce({false, []}, &strip_line/2)
      |> elem(1)
      |> Enum.reverse()
      |> Enum.join("\n")
    else
      block
    end
  end

  defp strip_line(line, {inside, kept}) do
    {inside, line} =
      if String.contains?(line, "<a2ui>"),
        do: {true, String.replace(line, "<a2ui>", "", global: false)},
        else: {inside, line}

    cond do
      String.contains?(line, "</a2ui>") ->
        [before | _] = String.split(line, "</a2ui>")
        {false, if(String.trim(before) != "", do: [before | kept], else: kept)}

      inside ->
        {true, [line | kept]}

      true ->
        {false, kept}
    end
  end

  defp statements(body, final?) do
    {:ok, statements, errors} = Syntax.parse(body)

    case {errors, final?} do
      {[{line, column, message, :lexer} | _], true} ->
        Failure.parse!("Syntax error at line #{line}:#{column}: #{message} (line #{line})",
          line: line,
          column: column
        )

      {[{line, column, message, :parser} | _], true} ->
        Failure.parse!(
          "Failed to parse expression: Syntax error at line #{line}:#{column}: #{message} " <>
            "(line #{line})",
          line: line,
          column: column
        )

      _final_or_clean ->
        statements
    end
  end

  # -- surfaces and statements -------------------------------------------------------

  # Units are `{:scope, index}`, `{:delete, surface_id}` and
  # `{:call, call, scope_index | nil}`; scopes are kept by index so that
  # assignments after a unit still reach its scope.
  defp units(catalogs, statements, surface_id) do
    initial = %{units: [], scopes: %{}, current: nil}

    acc =
      Enum.reduce(statements, initial, fn statement, acc ->
        unit_step(catalogs, statement, surface_id, acc)
      end)

    {Enum.reverse(acc.units), acc.scopes}
  end

  defp unit_step(catalogs, {:expr, {:call, "surface", args, kwargs}}, _default, acc) do
    surface = surface_call(catalogs, args, kwargs)
    open_scope(acc, surface)
  end

  defp unit_step(_catalogs, {:expr, {:call, "deleteSurface", args, kwargs}}, _default, acc) do
    target =
      case {args, lookup(kwargs, "surfaceId")} do
        {[id | _], _} when is_binary(id) -> id
        {_args, {:ok, id}} when is_binary(id) -> id
        _none -> nil
      end

    if target in [nil, ""],
      do: Failure.validation!("deleteSurface() requires the id of the surface to delete.")

    %{acc | units: [{:delete, target} | acc.units]}
  end

  defp unit_step(_catalogs, {:expr, {:call, _, _, _} = call}, _default, acc),
    do: %{acc | units: [{:call, call, acc.current} | acc.units]}

  defp unit_step(_catalogs, {:expr, _value}, _default, acc), do: acc

  defp unit_step(_catalogs, {:assign, target, value}, default, acc) do
    acc = if acc.current, do: acc, else: open_scope(acc, %{surface_id: default})
    field = if String.starts_with?(target, "$"), do: :data, else: :symbols
    update_in(acc.scopes[acc.current][field], &put_pair(&1, target, value))
  end

  defp open_scope(acc, surface) do
    index = map_size(acc.scopes)

    scope =
      Map.merge(%{send_data_model: nil, update: false, symbols: [], data: []}, surface)

    %{
      acc
      | scopes: Map.put(acc.scopes, index, scope),
        units: [{:scope, index} | acc.units],
        current: index
    }
  end

  defp surface_call(_catalogs, [], _kwargs),
    do: Failure.validation!(~s|surface() requires at least 1 argument: surface("surface_id").|)

  defp surface_call(_catalogs, [_, _, _ | _], _kwargs),
    do:
      Failure.validation!(
        "surface() takes at most 2 positional arguments: surface(id) or surface(id, catalogId)."
      )

  defp surface_call(catalogs, [surface_id | rest], kwargs) do
    unless is_binary(surface_id),
      do: Failure.validation!("The first argument to surface() must be a string literal.")

    catalog_id =
      case rest do
        [] ->
          ""

        [catalog_id] ->
          if match?({:ok, _}, lookup(kwargs, "catalogId")),
            do:
              Failure.validation!(
                "Duplicate catalogId in surface(): specified both positionally and as a " <>
                  "keyword argument."
              )

          unless is_binary(catalog_id),
            do:
              Failure.validation!("The second argument to surface() must be a catalog ID string.")

          catalog_id
      end

    surface = %{surface_id: surface_id, catalog_id: catalog_id}
    surface = Enum.reduce(kwargs, surface, &surface_keyword/2)
    check_surface_catalog(catalogs, surface)
    Map.delete(surface, :catalog_id)
  end

  defp surface_keyword({"catalogId", value}, surface) do
    unless is_binary(value),
      do: Failure.validation!("The catalogId argument to surface() must be a string.")

    %{surface | catalog_id: value}
  end

  defp surface_keyword({"sendDataModel", value}, surface) do
    unless is_boolean(value),
      do: Failure.validation!("The sendDataModel argument to surface() must be a boolean.")

    Map.put(surface, :send_data_model, value)
  end

  defp surface_keyword({"update", value}, surface) do
    unless is_boolean(value),
      do: Failure.validation!("The update argument to surface() must be a boolean.")

    Map.put(surface, :update, value)
  end

  defp surface_keyword({key, _value}, _surface),
    do: Failure.validation!("Unknown keyword argument '#{key}' in surface().")

  defp check_surface_catalog(_catalogs, %{catalog_id: ""}), do: :ok

  defp check_surface_catalog(%Catalogs{catalogs: [_, _ | _]}, %{catalog_id: catalog_id}) do
    Failure.validation!(
      "surface() names catalog '#{catalog_id}', but a surface names no catalog when several " <>
        "catalogs are active. Component and function names resolve across the active " <>
        ~s|catalogs, or take catalogId="..." when shared.|
    )
  end

  defp check_surface_catalog(%Catalogs{catalogs: [only]} = catalogs, surface) do
    if surface.catalog_id != only.catalog_id,
      do:
        Catalogs.unknown_catalog!(catalogs, "Surface '#{surface.surface_id}'", surface.catalog_id)

    :ok
  end

  # -- units -------------------------------------------------------------------------

  defp compile_unit(state, {:delete, surface_id}, calls),
    do: {[%{"version" => state.version, "deleteSurface" => %{"surfaceId" => surface_id}}], calls}

  defp compile_unit(state, {:call, call, scope_index}, calls) do
    unless Catalogs.v1?(state.version),
      do: Failure.validation!("Standalone function calls are not supported in A2UI v0.9")

    calls = calls + 1
    symbols = if scope_index, do: state.scopes[scope_index].symbols, else: []
    ctx = new_context(state, symbols, %{})
    {compiled, call_id, _ctx} = function_call(ctx, call, false, true)
    [first | _] = state.catalogs.catalogs

    call_function = Map.put_new(compiled, "catalogId", first.catalog_id)

    message = %{
      "version" => state.version,
      "callRendererFunction" => %{
        "functionCallId" => call_id || "call_#{calls}",
        "callFunction" => call_function
      }
    }

    {[message], calls}
  end

  defp compile_unit(state, {:scope, index}, calls),
    do: {compile_scope(state, state.scopes[index]), calls}

  defp new_context(state, symbols, ids) do
    %{
      catalogs: state.catalogs,
      version: state.version,
      keys: state.keys,
      symbols: symbols,
      ids: ids,
      extra: [],
      generated: %{},
      counter: 0,
      bound: %{},
      expanding: []
    }
  end

  defp compile_scope(state, scope) do
    ids = component_ids(state.catalogs, scope.symbols)
    ctx = new_context(state, scope.symbols, ids)

    {data_model, ctx} =
      Enum.reduce(scope.data, {%{}, ctx}, fn {path, value}, {data_model, ctx} ->
        {compiled, ctx} = value(ctx, value, false)
        {set_path(data_model, path, compiled), ctx}
      end)

    {components, ctx} =
      Enum.reduce(scope.symbols, {[], ctx}, fn {name, value}, {components, ctx} ->
        case component(ctx, name, value) do
          {nil, ctx} -> {components, ctx}
          {component, ctx} -> {[component | components], ctx}
        end
      end)

    components = Enum.reverse(components) ++ ctx.extra
    scope_messages(state, scope, components, data_model)
  end

  defp scope_messages(state, scope, components, data_model) do
    if scope.update or not Enum.any?(components, &(&1["id"] == "root")),
      do: update_messages(state, scope, components, data_model),
      else: create_messages(state, scope, components, data_model)
  end

  defp update_messages(state, scope, [], data_model) do
    if scope.data != [], do: [data_message(state, scope, data_model)], else: undefined_root!()
  end

  defp update_messages(state, scope, components, data_model),
    do: [components_message(state, scope, components) | data_messages(state, scope, data_model)]

  defp create_messages(state, scope, components, data_model) do
    if Catalogs.v1?(state.version) do
      create = Map.put(create_body(state, scope), "components", components)
      create = if data_model == %{}, do: create, else: Map.put(create, "dataModel", data_model)
      [%{"version" => state.version, "createSurface" => create}]
    else
      create = %{"version" => state.version, "createSurface" => create_body(state, scope)}

      [create, components_message(state, scope, components)] ++
        data_messages(state, scope, data_model)
    end
  end

  defp data_messages(_state, _scope, data_model) when data_model == %{}, do: []
  defp data_messages(state, scope, data_model), do: [data_message(state, scope, data_model)]

  defp create_body(state, scope) do
    body = %{"surfaceId" => scope.surface_id}

    body =
      case Catalogs.sole_catalog_id(state.catalogs) do
        nil -> body
        catalog_id -> Map.put(body, "catalogId", catalog_id)
      end

    if is_boolean(scope.send_data_model),
      do: Map.put(body, "sendDataModel", scope.send_data_model),
      else: body
  end

  defp components_message(state, scope, components),
    do: %{
      "version" => state.version,
      "updateComponents" => %{"surfaceId" => scope.surface_id, "components" => components}
    }

  defp data_message(state, scope, data_model),
    do: %{
      "version" => state.version,
      "updateDataModel" => %{
        "surfaceId" => scope.surface_id,
        "path" => "/",
        "value" => data_model
      }
    }

  @spec undefined_root!() :: no_return()
  defp undefined_root!,
    do:
      Failure.parse!("Root target 'root' is not defined.",
        help: "Ensure root component 'root' is assigned in your Express DSL."
      )

  # The component id of each variable assigned a component.
  defp component_ids(catalogs, symbols),
    do: Enum.reduce(symbols, %{}, &component_id(catalogs, &1, &2))

  defp component_id(catalogs, {name, {:call, component, _args, kwargs}}, ids) do
    id = explicit_id(component, kwargs)

    if defines_component?(catalogs, component, lookup(kwargs, "catalogId")),
      do: Map.put(ids, name, if(id == :absent, do: name, else: id)),
      else: ids
  end

  defp component_id(_catalogs, _symbol, ids), do: ids

  defp explicit_id(component, kwargs) do
    case lookup(kwargs, "id") do
      {:ok, id} when is_binary(id) and id != "" ->
        id

      {:ok, _invalid} ->
        Failure.validation!("id on component '#{component}' must be a non-empty string.")

      :error ->
        :absent
    end
  end

  @doc """
  Writes `value` at an Express data path (`$/a/b`) into `data_model`,
  creating the objects on the way. The path `$` writes nothing.

      iex> A2UIAgent.Express.Compiler.set_path(%{"a" => 1}, "$/user/name", "Ada")
      %{"a" => 1, "user" => %{"name" => "Ada"}}
  """
  @spec set_path(map(), String.t(), term()) :: map()
  def set_path(data_model, path, value) do
    relative =
      case path do
        "$/" <> rest -> rest
        "$" <> rest -> rest
        other -> other
      end

    if relative == "",
      do: data_model,
      else: put_path(data_model, String.split(relative, "/"), value)
  end

  defp put_path(map, [key], value), do: Map.put(map, key, value)

  defp put_path(map, [key | rest], value) do
    child =
      case Map.get(map, key) do
        %{} = child -> child
        _other -> %{}
      end

    Map.put(map, key, put_path(child, rest, value))
  end

  # -- components --------------------------------------------------------------------

  defp component(ctx, name, {:call, component, args, kwargs}) do
    catalog_option = lookup(kwargs, "catalogId")
    explicit = explicit_id(component, kwargs)
    kwargs = Enum.reject(kwargs, fn {key, _} -> key in ["catalogId", "id"] end)

    if not_a_component?(ctx, component, catalog_option) do
      {nil, ctx}
    else
      {helper, catalog_id} = resolve(ctx, :component, component, catalog_option)
      id = if explicit == :absent, do: Map.get(ctx.ids, name, name), else: explicit
      build_component(ctx, helper, catalog_id, id, component, args, kwargs)
    end
  end

  defp component(ctx, _name, _value), do: {nil, ctx}

  # A call that names a function, or one of Express's own helpers, is
  # not a component.
  defp not_a_component?(ctx, name, catalog_option) do
    not defines_component?(ctx.catalogs, name, catalog_option) and
      ((catalog_option == :error and name in @reserved_calls) or
         defines_function?(ctx.catalogs, name, catalog_option))
  end

  defp build_component(ctx, helper, catalog_id, id, component, args, kwargs) do
    properties = SchemaHelper.component_properties(helper, component)
    check_property = SchemaHelper.check_property(helper, component)
    positional = Enum.reject(properties, &(&1 == check_property))

    {checks, pairs} = split_arguments(args, kwargs, positional)
    base = %{"id" => id, "component" => component}
    base = if catalog_id, do: Map.put(base, "catalogId", catalog_id), else: base

    {compiled, seen, bound, ctx} =
      Enum.reduce(pairs, {base, [], %{}, ctx}, fn {property, arg}, acc ->
        property_argument(helper, component, id, properties, property, arg, acc)
      end)

    for required <- SchemaHelper.component_required(helper, component),
        required not in ["id", "component"],
        required not in seen do
      Failure.validation!("Component '#{component}' is missing required property '#{required}'.")
    end

    {compiled, ctx} =
      add_checks(%{ctx | bound: bound}, component, check_property, checks, compiled)

    {Map.reject(compiled, fn {_key, value} -> is_nil(value) end), %{ctx | bound: %{}}}
  end

  # Checks, and {property, argument} pairs: positional arguments take the
  # properties in order (extra ones are dropped), then keyword arguments.
  defp split_arguments(args, kwargs, positional) do
    {checks, pairs, _rest} =
      Enum.reduce(args, {[], [], positional}, fn arg, {checks, pairs, rest} ->
        cond do
          check_expression?(arg) -> {checks ++ List.wrap(arg), pairs, rest}
          rest == [] -> {checks, pairs, rest}
          true -> {checks, pairs ++ [{hd(rest), arg}], tl(rest)}
        end
      end)

    Enum.reduce(kwargs, {checks, pairs}, fn {key, value}, {checks, pairs} ->
      if check_expression?(value),
        do: {checks ++ List.wrap(value), pairs},
        else: {checks, pairs ++ [{key, value}]}
    end)
  end

  defp check_expression?({:check, _name, _args}), do: true
  defp check_expression?([_ | _] = list), do: Enum.all?(list, &check_expression?/1)
  defp check_expression?(_value), do: false

  defp property_argument(helper, component, id, properties, property, arg, acc) do
    {compiled, seen, bound, ctx} = acc

    unless property in properties do
      help =
        if properties == [],
          do: "Component '#{component}' has no configurable properties.",
          else:
            "Component '#{component}' accepts properties: #{Enum.join(Enum.sort(properties), ", ")}."

      Failure.validation!(
        "Property '#{property}' is not a valid property of component '#{component}'.",
        help: help
      )
    end

    if property in seen do
      Failure.validation!(
        "Property '#{property}' of component '#{component}' was provided multiple times.",
        help:
          "Remove duplicate specification of property '#{property}' for component '#{component}'."
      )
    end

    seen = [property | seen]

    if arg == :skipped do
      {Map.put(compiled, property, nil), seen, bound, ctx}
    else
      schema = SchemaHelper.property_schema(helper, component, property)
      action? = SchemaHelper.action_slot?(schema)
      {value, ctx} = value(ctx, arg, action?, %{parent: id, property: property})
      value = check_property_value(helper, component, property, schema, value)
      bound = if direct_path?(ctx.keys, value), do: Map.put(bound, property, value), else: bound
      {Map.put(compiled, property, value), seen, bound, ctx}
    end
  end

  defp check_property_value(helper, component, property, schema, value) do
    value =
      if schema != nil and not SchemaHelper.admits_path?(helper, schema) do
        check_bindings(helper, component, property, value, schema)

        if is_list(value) and SchemaHelper.option_objects?(schema),
          do: Enum.map(value, &option/1),
          else: value
      else
        value
      end

    enum = SchemaHelper.property_enum(helper, component, property)

    if is_list(enum) and is_binary(value) and value not in enum do
      allowed = "[" <> Enum.map_join(enum, ", ", &"'#{&1}'") <> "]"

      Failure.validation!(
        "Value '#{value}' is not a valid enum choice for property '#{property}' of component " <>
          "'#{component}'. Allowed values are: #{allowed}"
      )
    end

    value
  end

  defp option(value) when is_binary(value), do: %{"label" => value, "value" => value}
  defp option(value), do: value

  defp add_checks(ctx, _component, _property, [], compiled), do: {compiled, ctx}

  defp add_checks(_ctx, component, nil, _checks, _compiled) do
    Failure.validation!("Component '#{component}' does not accept checks.",
      help:
        "Remove the check expressions, or use a component whose schema declares a list of " <>
          "CheckRule."
    )
  end

  defp add_checks(ctx, _component, property, checks, compiled) do
    {rules, ctx} =
      Enum.map_reduce(checks, ctx, fn check, ctx -> check_rule(ctx, check, false) end)

    {Map.put(compiled, property, rules), ctx}
  end

  # A path binding that is not a template.
  defp direct_path?(keys, %{} = value) do
    Map.has_key?(value, keys.path) and not Map.has_key?(value, "componentId") and
      not Map.has_key?(value, keys.call) and not Map.has_key?(value, "event") and
      not Map.has_key?(value, "functionCall")
  end

  defp direct_path?(_keys, _value), do: false

  # A data binding is allowed only where the schema at its position
  # admits one.
  defp check_bindings(helper, component, property, value, schema) do
    if direct_path?(helper.keys, value) do
      if schema != nil and not SchemaHelper.admits_path?(helper, schema),
        do: forbidden_binding!(component, property)
    else
      check_nested_bindings(helper, component, property, value, schema)
    end
  end

  defp check_nested_bindings(helper, component, property, list, schema) when is_list(list) do
    items = schema && SchemaHelper.subschema(helper, schema, "items")
    Enum.each(list, &check_bindings(helper, component, property, &1, items))
  end

  defp check_nested_bindings(helper, component, property, %{} = map, schema) do
    unless call_or_action?(helper.keys, map) do
      Enum.each(map, fn {key, sub} ->
        sub_schema = schema && SchemaHelper.subschema(helper, schema, key)
        check_bindings(helper, component, property, sub, sub_schema)
      end)
    end
  end

  defp check_nested_bindings(_helper, _component, _property, _value, _schema), do: :ok

  defp call_or_action?(keys, value),
    do: Enum.any?([keys.call, "event", "functionCall"], &Map.has_key?(value, &1))

  @spec forbidden_binding!(String.t(), String.t()) :: no_return()
  defp forbidden_binding!(component, property) do
    Failure.validation!(
      "Property '#{property}' of component '#{component}' does not support dynamic data " <>
        "bindings (paths).",
      help:
        "Property '#{property}' on '#{component}' must be a static literal value, not a " <>
          "dynamic databinding ($path)."
    )
  end

  # -- checks and calls ----------------------------------------------------------------

  defp check_rule(ctx, {:check, name, args}, action?) do
    {catalog_option, remaining} = check_options(name, args)
    {helper, _catalog_id} = resolve(ctx, :function, name, catalog_option)
    parameters = SchemaHelper.function_properties(helper, name)

    {injected, offset} =
      with [first | _] <- parameters,
           false <- match?([{:path, _} | _], remaining),
           %{} = bound <- Map.get(ctx.bound, first) do
        {[{:path, to_string(Map.get(bound, ctx.keys.path, ""))}], 1}
      else
        _none -> {[], 0}
      end

    {call_args, message} =
      check_arguments(
        helper,
        name,
        parameters,
        remaining,
        offset,
        injected,
        default_message(name)
      )

    kwargs = if catalog_option == :error, do: [], else: [{"catalogId", elem(catalog_option, 1)}]

    {condition, _call_id, ctx} =
      function_call(ctx, {:call, name, call_args, kwargs}, action?, false)

    {%{"condition" => condition, "message" => message}, ctx}
  end

  @doc """
  The message a check rule gets when it names none: the check's name,
  capitalized, followed by `check failed`.

      iex> A2UIAgent.Express.Compiler.default_message("regex")
      "Regex check failed"
  """
  @spec default_message(String.t()) :: String.t()
  def default_message(name), do: "#{capitalize(name)} check failed"

  # Python's `str.capitalize`: the first letter upper case, the rest lower.
  defp capitalize(""), do: ""

  defp capitalize(name) do
    {first, rest} = String.split_at(name, 1)
    String.upcase(first) <> String.downcase(rest)
  end

  # A `{catalogId: ...}` map among a check's arguments names its catalog.
  defp check_options(name, args),
    do: Enum.reduce(args, {:error, []}, &check_option(name, &1, &2))

  defp check_option(name, {:map, pairs} = arg, {option, remaining}) do
    case lookup(pairs, "catalogId") do
      {:ok, catalog_id} ->
        check_option_keys(name, pairs)

        if option != :error and option != {:ok, catalog_id},
          do: Failure.validation!("Check '?#{name}' specifies conflicting catalogId values.")

        {{:ok, catalog_id}, remaining}

      :error ->
        {option, remaining ++ [arg]}
    end
  end

  defp check_option(_name, arg, {option, remaining}), do: {option, remaining ++ [arg]}

  defp check_option_keys(name, pairs) do
    case for {key, _} <- pairs, key != "catalogId", do: key do
      [] ->
        :ok

      others ->
        Failure.validation!(
          "Unsupported key(s) in check options for '?#{name}': " <>
            "#{Enum.join(others, ", ")}. Only 'catalogId' is allowed."
        )
    end
  end

  # The call's arguments and the rule's message: arguments past the
  # parameters, and a string given for a number or boolean parameter,
  # are the message.
  defp check_arguments(helper, name, parameters, remaining, offset, injected, message) do
    remaining
    |> Enum.with_index(offset)
    |> Enum.reduce_while({injected, message}, fn {arg, index}, acc ->
      check_argument(helper, name, Enum.at(parameters, index), arg, acc)
    end)
  end

  defp check_argument(_helper, _name, nil, arg, {call_args, message}),
    do: {:cont, {call_args, if(is_binary(arg), do: arg, else: message)}}

  defp check_argument(helper, name, parameter, arg, {call_args, message}) do
    schema = SchemaHelper.function_property_schema(helper, name, parameter)

    if is_binary(arg) and message_parameter?(schema),
      do: {:halt, {call_args, arg}},
      else: {:cont, {call_args ++ [arg], message}}
  end

  defp message_parameter?(schema),
    do: A2UICore.KeyOrder.get(schema, "type") in ["integer", "number", "boolean"]

  # {compiled call, explicit functionCallId or nil, ctx}
  defp function_call(ctx, {:call, name, args, kwargs}, action?, allow_call_id?) do
    catalog_option = lookup(kwargs, "catalogId")
    kwargs = Enum.reject(kwargs, fn {key, _} -> key == "catalogId" end)

    {call_id, kwargs} =
      case {allow_call_id?, lookup(kwargs, "functionCallId")} do
        {true, {:ok, id}} when is_binary(id) and id != "" ->
          {id, Enum.reject(kwargs, fn {key, _} -> key == "functionCallId" end)}

        {true, {:ok, _invalid}} ->
          Failure.validation!("functionCallId on function '#{name}' must be a non-empty string.")

        _other ->
          {nil, kwargs}
      end

    {helper, catalog_id} = resolve(ctx, :function, name, catalog_option)
    parameters = SchemaHelper.function_properties(helper, name)

    {compiled_args, ctx} =
      args
      |> Enum.zip(parameters)
      |> Enum.reduce({%{}, ctx}, fn
        {:skipped, _parameter}, acc ->
          acc

        {arg, parameter}, {compiled, ctx} ->
          {value, ctx} = value(ctx, arg, action?)
          {if(is_nil(value), do: compiled, else: Map.put(compiled, parameter, value)), ctx}
      end)

    {compiled_args, ctx} =
      Enum.reduce(kwargs, {compiled_args, ctx}, fn {key, arg}, {compiled, ctx} ->
        keyword_argument(ctx, name, parameters, key, arg, compiled, action?)
      end)

    call = %{ctx.keys.call => name, "args" => compiled_args}
    call = if catalog_id, do: Map.put(call, "catalogId", catalog_id), else: call
    {call, call_id, ctx}
  end

  defp keyword_argument(ctx, name, parameters, key, arg, compiled, action?) do
    unless key in parameters do
      help =
        if parameters == [],
          do: "Function '#{name}' accepts no parameters.",
          else:
            "Function '#{name}' accepts parameters: #{Enum.join(Enum.sort(parameters), ", ")}."

      Failure.validation!("Argument '#{key}' is not a valid parameter of function '#{name}'.",
        help: help
      )
    end

    if Map.has_key?(compiled, key) do
      Failure.validation!("Argument '#{key}' of function '#{name}' was provided multiple times.",
        help: "Remove duplicate specification of parameter '#{key}' for function '#{name}'."
      )
    end

    if arg == :skipped do
      {compiled, ctx}
    else
      {value, ctx} = value(ctx, arg, action?)
      {if(is_nil(value), do: compiled, else: Map.put(compiled, key, value)), ctx}
    end
  end

  # -- values ----------------------------------------------------------------------------

  defp value(ctx, value, action?, inline \\ nil)

  defp value(ctx, {:path, path}, _action?, _inline), do: {%{ctx.keys.path => path}, ctx}

  defp value(ctx, {:var, name}, action?, _inline) do
    cond do
      Map.has_key?(ctx.ids, name) ->
        {Map.fetch!(ctx.ids, name), ctx}

      List.keymember?(ctx.symbols, name, 0) ->
        if name in ctx.expanding,
          do: Failure.validation!("Variable '#{name}' is defined in terms of itself.")

        {_name, symbol} = List.keyfind(ctx.symbols, name, 0)
        {value, ctx} = value(%{ctx | expanding: [name | ctx.expanding]}, symbol, action?)
        {value, %{ctx | expanding: tl(ctx.expanding)}}

      true ->
        {name, ctx}
    end
  end

  defp value(ctx, {:check, _, _} = check, action?, _inline) do
    {rule, ctx} = check_rule(ctx, check, action?)
    {rule["condition"], ctx}
  end

  defp value(ctx, {:call, "_template", args, _kwargs}, action?, _inline) do
    case args do
      [path_arg, component_arg | _] ->
        {path, ctx} = value(ctx, path_arg, action?)

        unless is_map(path) and Map.has_key?(path, ctx.keys.path),
          do:
            Failure.parse!(
              "The first argument to _template must be a dynamic data binding path (prefixed " <>
                "by $), got: #{format_value(path_arg)}"
            )

        {component_id, ctx} = value(ctx, component_arg, action?)
        {%{"path" => path[ctx.keys.path], "componentId" => component_id}, ctx}

      _too_few ->
        Failure.parse!(
          "_template helper requires exactly 2 arguments: path and templateComponent."
        )
    end
  end

  defp value(ctx, {:call, "Event", args, _kwargs}, action?, _inline) do
    {name, ctx} =
      case args do
        [first | _] -> value(ctx, first, action?)
        [] -> {"", ctx}
      end

    case args do
      [_, context_arg | _] ->
        {context, ctx} = value(ctx, context_arg, action?)
        {%{"event" => %{"name" => name, "context" => event_context(context)}}, ctx}

      _no_context ->
        {%{"event" => %{"name" => name}}, ctx}
    end
  end

  defp value(ctx, {:call, name, _args, kwargs} = call, action?, inline) do
    if defines_component?(ctx.catalogs, name, lookup(kwargs, "catalogId")) do
      inline_component(ctx, call, inline)
    else
      {compiled, _call_id, ctx} = function_call(ctx, call, false, false)
      {if(action?, do: %{"functionCall" => compiled}, else: compiled), ctx}
    end
  end

  defp value(ctx, list, action?, inline) when is_list(list) do
    list
    |> Enum.with_index()
    |> Enum.map_reduce(ctx, fn {item, index}, ctx ->
      value(ctx, item, action?, inline && Map.put(inline, :index, index))
    end)
  end

  defp value(ctx, {:map, pairs}, action?, _inline) do
    {compiled, ctx} =
      Enum.map_reduce(pairs, ctx, fn {key, item}, ctx ->
        {compiled, ctx} = value(ctx, item, action?)
        {{key, compiled}, ctx}
      end)

    {Map.new(compiled), ctx}
  end

  defp value(ctx, :skipped, _action?, _inline), do: {%{"skipped" => true}, ctx}
  defp value(ctx, literal, _action?, _inline), do: {literal, ctx}

  defp event_context(context) when is_list(context),
    do: context |> Enum.filter(&is_map/1) |> Enum.reduce(%{}, &Map.merge(&2, &1))

  defp event_context(%{} = context), do: context
  defp event_context(_context), do: %{}

  defp inline_component(ctx, call, inline) do
    ctx = %{ctx | counter: ctx.counter + 1}

    id =
      case inline do
        %{parent: parent, property: property, index: index} -> "#{parent}_#{property}_#{index}"
        %{parent: parent, property: property} -> "#{parent}_#{property}"
        nil -> "_inline_#{ctx.counter}"
      end

    if List.keymember?(ctx.symbols, id, 0) or id in Map.values(ctx.ids) or
         Map.has_key?(ctx.generated, id) do
      Failure.validation!(
        "Generated inline component ID '#{id}' collides with an existing component or variable ID."
      )
    end

    ctx = %{ctx | generated: Map.put(ctx.generated, id, true)}
    {before, ctx} = {ctx.extra, %{ctx | extra: []}}
    bound = ctx.bound

    {compiled, ctx} = component(ctx, id, call)
    {compiled["id"], %{ctx | extra: before ++ [compiled | ctx.extra], bound: bound}}
  end

  defp format_value(value) when is_binary(value), do: value
  defp format_value({:var, name}), do: Jason.encode!(%{"variable" => name})
  defp format_value(value), do: inspect(value)

  # -- catalog lookups ---------------------------------------------------------------------

  defp defines_component?(catalogs, name, {:ok, catalog_id}) when is_binary(catalog_id) do
    case Catalogs.helper(catalogs, catalog_id) do
      nil -> Catalogs.defining(catalogs, :component, name) != []
      helper -> SchemaHelper.component?(helper, name)
    end
  end

  defp defines_component?(catalogs, name, _option),
    do: Catalogs.defining(catalogs, :component, name) != []

  defp defines_function?(catalogs, name, {:ok, catalog_id}) do
    case is_binary(catalog_id) && Catalogs.helper(catalogs, catalog_id) do
      %SchemaHelper{} = helper -> SchemaHelper.function?(helper, name)
      _none -> false
    end
  end

  defp defines_function?(catalogs, name, :error),
    do: Catalogs.defining(catalogs, :function, name) != []

  # {helper, catalogId to write or nil}
  defp resolve(ctx, kind, name, {:ok, catalog_id}) do
    catalogs = ctx.catalogs
    label = Catalogs.label(kind)

    unless Catalogs.v1?(ctx.version),
      do:
        Failure.validation!(
          "catalogId on a component or function call is only supported in A2UI v1.0 or later."
        )

    unless is_binary(catalog_id) and catalog_id != "",
      do: Failure.validation!("catalogId on #{kind} '#{name}' must be a non-empty string.")

    case Catalogs.helper(catalogs, catalog_id) do
      nil ->
        Catalogs.unknown_catalog!(catalogs, "#{label} '#{name}'", catalog_id)

      helper ->
        unless Catalogs.defines?(helper, kind, name),
          do: Catalogs.unknown_symbol!(catalogs, kind, name, catalog_id)

        {helper, catalog_id}
    end
  end

  defp resolve(ctx, kind, name, :error) do
    catalogs = ctx.catalogs

    case Catalogs.defining(catalogs, kind, name) do
      [] ->
        Catalogs.unknown_symbol!(catalogs, kind, name, nil)

      [catalog_id] ->
        written = if length(catalogs.catalogs) > 1, do: catalog_id
        {Catalogs.helper(catalogs, catalog_id), written}

      ids ->
        Failure.validation!(
          "#{Catalogs.label(kind)} '#{name}' is defined in several catalogs: " <>
            Enum.map_join(ids, ", ", &"'#{&1}'") <>
            ". Name the catalog to use with a catalogId argument."
        )
    end
  end

  defp lookup(pairs, key) do
    case List.keyfind(pairs, key, 0) do
      {^key, value} -> {:ok, value}
      nil -> :error
    end
  end

  defp put_pair(pairs, key, value) do
    if List.keymember?(pairs, key, 0),
      do: List.keyreplace(pairs, key, 0, {key, value}),
      else: pairs ++ [{key, value}]
  end
end

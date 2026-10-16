defmodule A2UIAgent.Express.Decompiler do
  @moduledoc """
  Writes A2UI messages back as Express.

      {:ok, catalogs} = A2UIAgent.Express.Catalogs.new([catalog])

      A2UIAgent.Express.Decompiler.decompile(catalogs, [
        %{"version" => "v1.0", "deleteSurface" => %{"surfaceId" => "s1"}}
      ])
      #=> {:ok, ~s|deleteSurface("s1")|}

  Messages are first coalesced: an `updateComponents`, and a root
  `updateDataModel` with an object value, that follow a `createSurface`
  for the same surface merge into it while that does not change what the
  messages mean. Each surface becomes a `surface(...)` block (left out
  for the default surface at the start), an update stays an update
  (`update=true` when it carries a `root`), and deletes and renderer
  function calls become statements of their own.

  Components are written positionally in the order
  `A2UIAgent.Express.SchemaHelper` gives, with `_` for a skipped
  property; an id that is not an Express identifier gets a derived
  variable name and an `id=` argument. A check whose `value` argument is
  the component's own binding leaves it implicit, and a message other
  than the default is written after the parameters. Data model values
  are written one assignment per leaf, in path order. The result
  compiles back to the same messages.

  Map keys and event context keys are written in the order the message
  has them: a message read with `objects: :ordered_objects` keeps its
  order.
  """

  alias A2UIAgent.Express.{Catalogs, Compiler, Failure, SchemaHelper, Syntax}
  alias A2UICore.{Error, KeyOrder}
  alias Jason.OrderedObject

  @moduledoc since: "0.1.0"

  @default_surface "default_surface"
  @operations ~w(createSurface updateComponents updateDataModel deleteSurface)

  @doc """
  Decompiles `messages` (a list, or one message). A component or
  function the catalogs do not define is a `:validation` error.

  With several catalogs, a component that names no `catalogId` belongs to
  its surface's catalog, which the surface's `createSurface` names. For
  messages that update surfaces created earlier, pass those surfaces'
  catalogs as the `:surface_catalogs` option, a map of catalog ids by
  surface id.
  """
  @spec decompile(Catalogs.t(), [map()] | map(), keyword()) ::
          {:ok, String.t()} | {:error, Error.t()}
  def decompile(%Catalogs{} = catalogs, messages, options \\ []) do
    known = Map.new(Keyword.get(options, :surface_catalogs, %{}))
    {:ok, decompile!(catalogs, List.wrap(messages), known)}
  rescue
    failure in Failure -> {:error, Failure.to_error(failure)}
  end

  defp decompile!(catalogs, messages, known) do
    {blocks, _calls} =
      messages
      |> coalesce(known)
      |> Enum.with_index()
      |> Enum.flat_map_reduce(0, fn {item, index}, calls ->
        cond do
          empty?(item.message) ->
            {[], calls}

          renderer_call?(item.message) ->
            {[renderer_call(catalogs, item.message, calls + 1)], calls + 1}

          true ->
            {List.wrap(item_block(catalogs, item, index == 0)), calls}
        end
      end)

    blocks |> Enum.reject(&(&1 in [nil, ""])) |> Enum.join("\n")
  end

  @doc """
  Encloses decompiled blocks in one pair of `<a2ui>` tags.

      iex> A2UIAgent.Express.Decompiler.wrap_decompiled_blocks([~s|root = Text("a")|])
      ~s|<a2ui>\\nroot = Text("a")\\n</a2ui>|
  """
  @spec wrap_decompiled_blocks([String.t()]) :: String.t()
  def wrap_decompiled_blocks(blocks), do: "<a2ui>\n#{Enum.join(blocks, "\n")}\n</a2ui>"

  # -- coalescing --------------------------------------------------------------------

  # Each item: %{message, operation, surface_id, surface_catalog_id}.
  defp coalesce(messages, known) do
    {result, _open} =
      Enum.reduce(messages, {[], %{}}, fn message, {result, open} ->
        coalesce_step(message, result, open)
      end)

    {items, _seen} =
      result
      |> Enum.reverse()
      |> Enum.map_reduce(known, fn {message, operation, surface_id}, seen ->
        seen = track_catalog(seen, message, operation, surface_id)

        item = %{
          message: message,
          operation: operation,
          surface_id: surface_id,
          surface_catalog_id: if(is_binary(surface_id), do: Map.get(seen, surface_id))
        }

        {item, seen}
      end)

    items
  end

  defp coalesce_step(message, result, open) do
    case operation(message) do
      nil ->
        {[{message, nil, nil} | result], %{}}

      "createSurface" ->
        surface_id = get(get(message, "createSurface"), "surfaceId")
        open = if is_binary(surface_id), do: Map.put(open, surface_id, length(result)), else: open
        {[{message, "createSurface", surface_id} | result], open}

      operation ->
        body = get(message, operation)
        surface_id = get(body, "surfaceId")
        merge_or_keep(message, operation, body, surface_id, result, open)
    end
  end

  defp merge_or_keep(message, operation, body, surface_id, result, open) do
    case is_binary(surface_id) && Map.fetch(open, surface_id) do
      {:ok, index} ->
        position = length(result) - 1 - index
        {create, "createSurface", create_id} = Enum.at(result, position)
        create_body = get(create, "createSurface")

        case merge(operation, body, create_body) do
          {:merged, create_body} ->
            create = put(create, "createSurface", create_body)
            {List.replace_at(result, position, {create, "createSurface", create_id}), open}

          :keep ->
            {[{message, operation, surface_id} | result], Map.delete(open, surface_id)}
        end

      _not_open ->
        open = if operation == "deleteSurface", do: Map.delete(open, surface_id), else: open
        {[{message, operation, surface_id} | result], open}
    end
  end

  defp merge("updateComponents", body, create_body) do
    if has?(create_body, "components"),
      do: :keep,
      else: {:merged, put(create_body, "components", get(body, "components") || [])}
  end

  defp merge("updateDataModel", body, create_body) do
    value = get(body, "value")

    if get(body, "path") in [nil, "", "/"] and is_map(value),
      do: {:merged, put(create_body, "dataModel", value)},
      else: :keep
  end

  defp merge(_operation, _body, _create_body), do: :keep

  defp track_catalog(seen, message, "createSurface", surface_id) when is_binary(surface_id) do
    case get(get(message, "createSurface"), "catalogId") do
      catalog_id when is_binary(catalog_id) and catalog_id != "" ->
        Map.put(seen, surface_id, catalog_id)

      _none ->
        Map.delete(seen, surface_id)
    end
  end

  defp track_catalog(seen, _message, _operation, _surface_id), do: seen

  defp operation(message),
    do: Enum.find(@operations, fn key -> is_map(get(message, key)) end)

  defp renderer_call?(message),
    do: has?(message, "callRendererFunction") or has?(message, "callFunction")

  # -- surfaces ----------------------------------------------------------------------

  defp item_block(_catalogs, %{operation: "deleteSurface", message: message}, _first?) do
    surface_id = get(get(message, "deleteSurface"), "surfaceId") || ""
    "deleteSurface(#{string(to_string(surface_id))})"
  end

  defp item_block(catalogs, %{operation: operation} = item, first?)
       when operation in ["updateComponents", "updateDataModel"],
       do: update_block(catalogs, item, first?)

  defp item_block(catalogs, item, first?) do
    create = get(item.message, "createSurface") || %{}
    surface_id = non_empty(get(create, "surfaceId")) || @default_surface

    catalog_id =
      surface_catalog(catalogs, non_empty(get(create, "catalogId")) || item.surface_catalog_id)

    send_data_model = get(create, "sendDataModel")

    header =
      if first? and surface_id == @default_surface and is_nil(send_data_model) do
        []
      else
        flag =
          if is_nil(send_data_model), do: "", else: ", sendDataModel=#{truthy?(send_data_model)}"

        ["surface(#{string(surface_id)}#{flag})"]
      end

    data_model = get(create, "dataModel")

    data_lines =
      if truthy?(data_model), do: data_lines(catalogs, data_model, "", catalog_id), else: []

    components = List.wrap(get(create, "components"))
    Enum.join(header ++ data_lines ++ components(catalogs, components, catalog_id), "\n")
  end

  defp update_block(catalogs, item, first?) do
    body = get(item.message, item.operation)
    surface_id = non_empty(get(body, "surfaceId")) || @default_surface
    catalog_id = surface_catalog(catalogs, item.surface_catalog_id)

    components =
      if item.operation == "updateComponents", do: List.wrap(get(body, "components")), else: []

    root? = Enum.any?(components, &(is_map(&1) and get(&1, "id") == "root"))
    update = if root?, do: ", update=true", else: ""

    header =
      if root? or not (first? and surface_id == @default_surface),
        do: ["surface(#{string(surface_id)}#{update})"],
        else: []

    lines =
      if item.operation == "updateComponents",
        do: components(catalogs, components, catalog_id),
        else: update_data_lines(catalogs, body, catalog_id)

    Enum.join(header ++ lines, "\n")
  end

  defp update_data_lines(catalogs, body, catalog_id) do
    raw_path = non_empty(get(body, "path")) || "/"
    value = get(body, "value")
    base = String.trim_trailing(raw_path, "/")

    if is_map(value) and not empty?(value),
      do: data_lines(catalogs, value, base, catalog_id),
      else: ["#{path(raw_path)} = #{value(catalogs, value, %{}, false, catalog_id)}"]
  end

  # One assignment per leaf, in path order.
  defp data_lines(catalogs, data, base, catalog_id) do
    data
    |> flatten(base)
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.map(fn {leaf, value} ->
      "$#{leaf} = #{value(catalogs, value, %{}, false, catalog_id)}"
    end)
  end

  defp flatten(value, path) do
    if is_map(value) and not empty?(value),
      do: Enum.flat_map(pairs(value), fn {key, child} -> flatten(child, "#{path}/#{key}") end),
      else: [{path, value}]
  end

  # With one catalog, a surface's catalog is that catalog (and naming
  # another fails); with several, it is what the messages name.
  defp surface_catalog(catalogs, catalog_id) do
    case Catalogs.sole_catalog_id(catalogs) do
      nil ->
        catalog_id

      sole ->
        if catalog_id != nil and Catalogs.helper(catalogs, catalog_id) == nil,
          do: unknown_catalog!(catalogs, catalog_id)

        sole
    end
  end

  @spec unknown_catalog!(Catalogs.t(), term()) :: no_return()
  defp unknown_catalog!(catalogs, catalog_id) do
    available = Enum.map_join(catalogs.helpers, ", ", &"'#{&1.catalog_id}'")
    Failure.validation!("Unknown catalog '#{catalog_id}'. Available catalogs: [#{available}]")
  end

  # -- renderer calls ----------------------------------------------------------------

  defp renderer_call(catalogs, message, index) do
    {call, call_id} =
      case get(message, "callRendererFunction") do
        %{} = renderer -> {get(renderer, "callFunction"), get(renderer, "functionCallId")}
        _none -> {get(message, "callFunction"), nil}
      end

    call = if is_map(call), do: call, else: %{}
    written = call(catalogs, call, %{}, Catalogs.sole_catalog_id(catalogs))

    if is_binary(call_id) and call_id != "" and call_id != "call_#{index}" do
      separator = if String.ends_with?(written, "()"), do: "", else: ", "
      String.slice(written, 0..-2//1) <> "#{separator}functionCallId=#{string(call_id)})"
    else
      written
    end
  end

  # -- components ----------------------------------------------------------------------

  defp components(catalogs, components, surface_catalog_id) do
    names = variable_names(Enum.map(components, &to_string(get(&1, "id"))))
    Enum.map(components, &component(catalogs, &1, names, surface_catalog_id))
  end

  defp component(catalogs, component, names, surface_catalog_id) do
    id = to_string(get(component, "id"))
    name = get(component, "component")

    {helper, catalog_id} =
      resolve(catalogs, :component, name, get(component, "catalogId"), surface_catalog_id)

    properties = SchemaHelper.component_properties(helper, name)
    check_property = SchemaHelper.check_property(helper, name)

    args =
      properties
      |> Enum.with_index()
      |> Enum.flat_map(fn {property, index} ->
        if property == check_property do
          [checks(catalogs, component, property, names, surface_catalog_id)]
        else
          later = Enum.drop(properties, index + 1)

          argument(
            catalogs,
            helper,
            component,
            property,
            later,
            check_property,
            names,
            surface_catalog_id
          )
        end
      end)
      |> strip_placeholders()

    args = if catalog_id, do: args ++ ["catalogId=#{string(catalog_id)}"], else: args
    variable = Map.fetch!(names, id)
    args = if variable != id, do: args ++ ["id=#{string(id)}"], else: args
    "#{variable} = #{name}(#{Enum.join(args, ", ")})"
  end

  defp argument(catalogs, helper, component, property, later, check_property, names, catalog_id) do
    cond do
      has?(component, property) ->
        schema = SchemaHelper.property_schema(helper, get(component, "component"), property)
        ref? = component_reference?(schema)
        [value(catalogs, get(component, property), names, ref?, catalog_id)]

      Enum.any?(later, &(&1 != check_property and has?(component, &1))) ->
        ["_"]

      true ->
        []
    end
  end

  defp checks(catalogs, component, property, names, catalog_id) do
    case List.wrap(get(component, property)) do
      [] ->
        "_"

      [single] ->
        check(catalogs, single, component, names, catalog_id)

      rules ->
        "[" <>
          Enum.map_join(rules, ", ", &check(catalogs, &1, component, names, catalog_id)) <> "]"
    end
  end

  defp check(catalogs, rule, component, names, surface_catalog_id) do
    rule =
      if not has?(rule, "condition") and call_key?(rule), do: %{"condition" => rule}, else: rule

    condition = condition!(get(rule, "condition"))
    name = reserved(condition, "call")
    args = get(condition, "args") || %{}

    {helper, catalog_id} =
      resolve(catalogs, :function, name, get(condition, "catalogId"), surface_catalog_id)

    parameters = SchemaHelper.function_properties(helper, name)
    skip = if implicit_value?(parameters, args, get(component, "value")), do: 1, else: 0

    written =
      parameters
      |> Enum.drop(skip)
      |> Enum.map(fn parameter ->
        if has?(args, parameter),
          do: value(catalogs, get(args, parameter), names, false, surface_catalog_id),
          else: "_"
      end)
      |> with_message(get(rule, "message"), name)

    written = if catalog_id, do: written ++ ["{catalogId: #{string(catalog_id)}}"], else: written
    if written == [], do: "?#{name}", else: "?#{name}(#{Enum.join(written, ", ")})"
  end

  defp condition!(condition) do
    if is_map(condition) and call_key?(condition) do
      condition
    else
      Failure.validation!(
        "Express cannot write a check whose condition is not a function call: " <>
          inspect(KeyOrder.to_plain(condition))
      )
    end
  end

  # The compiler passes the component's bound `value` as a check's first
  # `value` argument, so that argument is left out when it is that.
  defp implicit_value?(["value" | _], args, own_value) do
    is_map(own_value) and path_key?(own_value) and
      KeyOrder.to_plain(get(args, "value")) == KeyOrder.to_plain(own_value)
  end

  defp implicit_value?(_parameters, _args, _own_value), do: false

  # A message other than the compiler's default goes after every
  # parameter; without one, trailing placeholders go.
  defp with_message(written, message, name) do
    if is_binary(message) and message != "" and message != Compiler.default_message(name),
      do: written ++ [string(message)],
      else: strip_placeholders(written)
  end

  defp call(catalogs, call, names, surface_catalog_id) do
    name = reserved(call, "call") || ""
    args = get(call, "args") || %{}

    {helper, catalog_id} =
      resolve(catalogs, :function, name, get(call, "catalogId"), surface_catalog_id)

    written =
      helper
      |> SchemaHelper.function_properties(name)
      |> Enum.with_index()
      |> Enum.map(fn {parameter, index} ->
        case call_argument(args, parameter, index) do
          {:ok, value} -> value(catalogs, value, names, false, surface_catalog_id)
          :error -> "_"
        end
      end)
      |> strip_placeholders()

    written = if catalog_id, do: written ++ ["catalogId=#{string(catalog_id)}"], else: written
    "#{name}(#{Enum.join(written, ", ")})"
  end

  defp call_argument(args, _parameter, index) when is_list(args) do
    if index < length(args), do: {:ok, Enum.at(args, index)}, else: :error
  end

  defp call_argument(args, parameter, _index) do
    if has?(args, parameter), do: {:ok, get(args, parameter)}, else: :error
  end

  # {helper, catalogId to write or nil}: the catalog is named only when
  # several catalogs are active and a lookup by name would not find it.
  defp resolve(catalogs, kind, name, catalog_id, surface_catalog_id) do
    actual = non_empty(catalog_id) || surface_catalog_id
    label = if kind == :component, do: "component", else: "function"

    if is_nil(actual) do
      Failure.validation!(
        "#{String.capitalize(label)} '#{name}' names no catalogId, and its surface has no catalog."
      )
    end

    helper = Catalogs.helper(catalogs, actual) || unknown_catalog!(catalogs, actual)

    unless is_binary(name) and Catalogs.defines?(helper, kind, name),
      do: Failure.validation!("Unknown #{label} '#{name}' not defined in catalog '#{actual}'.")

    {helper, written_catalog(catalogs, kind, name, actual)}
  end

  defp written_catalog(catalogs, kind, name, actual) do
    if Catalogs.sole_catalog_id(catalogs) || Catalogs.defining(catalogs, kind, name) == [actual],
      do: nil,
      else: actual
  end

  # -- values ----------------------------------------------------------------------------

  defp value(catalogs, value, names, ref?, catalog_id) when is_map(value) do
    cond do
      path_key?(value) ->
        path = reserved(value, "path")

        if has?(value, "componentId"),
          do: "_template(#{path(path)}, #{reference(get(value, "componentId"), names)})",
          else: path(path)

      has?(value, "event") ->
        event(catalogs, get(value, "event"), names, catalog_id)

      has?(value, "functionCall") ->
        call(catalogs, get(value, "functionCall"), names, catalog_id)

      call_key?(value) ->
        call(catalogs, value, names, catalog_id)

      true ->
        entries =
          Enum.map(pairs(value), fn {key, item} ->
            item_ref? = ref? or key in ["child", "componentId"]
            "#{key(key)}: #{value(catalogs, item, names, item_ref?, catalog_id)}"
          end)

        "{#{Enum.join(entries, ", ")}}"
    end
  end

  defp value(catalogs, list, names, ref?, catalog_id) when is_list(list),
    do: "[" <> Enum.map_join(list, ", ", &value(catalogs, &1, names, ref?, catalog_id)) <> "]"

  defp value(_catalogs, text, names, true, _catalog_id) when is_binary(text),
    do: reference(text, names)

  defp value(_catalogs, text, _names, false, _catalog_id) when is_binary(text), do: string(text)
  defp value(_catalogs, true, _names, _ref?, _catalog_id), do: "true"
  defp value(_catalogs, false, _names, _ref?, _catalog_id), do: "false"
  defp value(_catalogs, nil, _names, _ref?, _catalog_id), do: "null"

  defp value(_catalogs, number, _names, _ref?, _catalog_id) when is_number(number),
    do: number(number)

  defp value(_catalogs, other, _names, _ref?, _catalog_id), do: string(inspect(other))

  defp event(catalogs, event, names, catalog_id) do
    name = string(to_string(get(event, "name") || ""))
    context = get(event, "context")

    if has?(event, "context") do
      entries =
        Enum.map(pairs(context || %{}), fn {key, item} ->
          "#{key(key)}: #{value(catalogs, item, names, false, catalog_id)}"
        end)

      "Event(#{name}, {#{Enum.join(entries, ", ")}})"
    else
      "Event(#{name})"
    end
  end

  @doc """
  Writes a number as Python's `str` does: integers as they are, floats
  with a decimal point (`1500.0`), or in exponent form outside
  `1e-4 <= |x| < 1e16`.

      iex> A2UIAgent.Express.Decompiler.number(1500.0)
      "1500.0"
      iex> A2UIAgent.Express.Decompiler.number(0.1)
      "0.1"
  """
  @spec number(number()) :: String.t()
  def number(number) when is_integer(number), do: Integer.to_string(number)

  def number(float) when is_float(float) and float == 0.0, do: "0.0"

  def number(float) when is_float(float) do
    sign = if float < 0, do: "-", else: ""
    {digits, point} = decimal(abs(float))
    sign <> python_float(digits, point)
  end

  # The shortest digits that read back as `float`, and where the decimal
  # point goes: `{"15", 4}` for 1500.0.
  defp decimal(float) do
    {mantissa, exponent} =
      case float |> :erlang.float_to_binary([:short]) |> String.split("e") do
        [mantissa, exponent] -> {mantissa, String.to_integer(exponent)}
        [mantissa] -> {mantissa, 0}
      end

    [whole, fraction] = String.split(mantissa, ".")

    raw = whole <> fraction
    trimmed = String.trim_trailing(raw, "0")
    last = exponent - String.length(fraction) + String.length(raw) - String.length(trimmed)
    digits = String.trim_leading(trimmed, "0")
    {digits, last + String.length(digits)}
  end

  defp python_float(digits, point) do
    count = String.length(digits)

    cond do
      point - 1 < -4 or point - 1 >= 16 ->
        {first, rest} = String.split_at(digits, 1)
        mantissa = if rest == "", do: first, else: "#{first}.#{rest}"
        exponent = point - 1
        sign = if exponent < 0, do: "-", else: "+"
        mantissa <> "e" <> sign <> String.pad_leading(Integer.to_string(abs(exponent)), 2, "0")

      point <= 0 ->
        "0." <> String.duplicate("0", -point) <> digits

      point >= count ->
        digits <> String.duplicate("0", point - count) <> ".0"

      true ->
        {whole, fraction} = String.split_at(digits, point)
        whole <> "." <> fraction
    end
  end

  @doc """
  Writes a string as the most readable Express literal: a triple-quoted
  string for several lines, a raw string for backslashes, otherwise a
  quoted string with escapes.

      iex> A2UIAgent.Express.Decompiler.string(~S(C:\\temp))
      ~S(r"C:\\temp")
      iex> A2UIAgent.Express.Decompiler.string(~s(say "hi"))
      ~S("say \\"hi\\"")
  """
  @spec string(String.t()) :: String.t()
  def string(text) do
    newline? = String.contains?(text, ["\n", "\r"])
    plain? = not String.contains?(text, ["\t", "\""])

    cond do
      newline? and not String.ends_with?(text, "\"") and not String.contains?(text, ~s(""")) ->
        triple_quoted(text)

      String.contains?(text, "\\") and not newline? and plain? ->
        ~s(r") <> text <> ~s(")

      true ->
        replacements = [
          {"\\", "\\\\"},
          {"\"", "\\\""},
          {"\n", "\\n"},
          {"\r", "\\r"},
          {"\t", "\\t"}
        ]

        ~s(") <> escape(text, replacements) <> ~s(")
    end
  end

  # Several lines: raw when there are backslashes but no tabs.
  defp triple_quoted(text) do
    if String.contains?(text, "\\") and not String.contains?(text, "\t"),
      do: ~s(r""") <> text <> ~s("""),
      else: ~s(""") <> escape(text, [{"\\", "\\\\"}, {"\t", "\\t"}]) <> ~s(""")
  end

  defp escape(text, replacements) do
    {pattern, map} = {Enum.map(replacements, &elem(&1, 0)), Map.new(replacements)}
    String.replace(text, pattern, &Map.fetch!(map, &1))
  end

  defp key(key), do: if(Syntax.identifier?(key), do: key, else: string(key))

  defp path("/" <> rest), do: "$/" <> rest
  defp path(path) when is_binary(path), do: "$" <> path
  defp path(path), do: "$" <> to_string(path)

  # A reference to a component: its variable when the block defines it,
  # a bare name the block does not use, or else a quoted id.
  defp reference(id, names) when is_binary(id) do
    cond do
      Map.has_key?(names, id) -> Map.fetch!(names, id)
      Syntax.identifier?(id) and id not in Map.values(names) -> id
      true -> string(id)
    end
  end

  defp reference(id, _names), do: string(to_string(id))

  @doc false
  # The variable each component id is written under: the id itself when
  # it is an identifier, else a derived name no other id or variable
  # takes.
  @spec variable_names([String.t()]) :: %{optional(String.t()) => String.t()}
  def variable_names(ids) do
    own = for id <- ids, Syntax.identifier?(id), into: %{}, do: {id, id}

    taken = Map.new(own, fn {_id, name} -> {name, true} end)

    {names, _taken} = Enum.reduce(ids, {own, taken}, &derive_name/2)
    names
  end

  defp derive_name(id, {names, taken}) do
    if Map.has_key?(names, id) do
      {names, taken}
    else
      base = String.replace(id, ~r/[^a-zA-Z0-9_]/, "_")
      base = if base != "" and Syntax.identifier?(base), do: base, else: "_" <> base
      name = unused(base, taken, 2, base)
      {Map.put(names, id, name), Map.put(taken, name, true)}
    end
  end

  defp unused(name, taken, suffix, base) do
    if Map.has_key?(taken, name),
      do: unused("#{base}_#{suffix}", taken, suffix + 1, base),
      else: name
  end

  defp component_reference?(schema) do
    ref = KeyOrder.get(schema, "$ref")

    is_map(schema) and
      ((is_binary(ref) and String.contains?(ref, ["ComponentId", "Child", "ChildList"])) or
         Enum.any?(["oneOf", "anyOf", "allOf"], fn key ->
           schema |> KeyOrder.get(key) |> List.wrap() |> Enum.any?(&component_reference?/1)
         end) or
         (KeyOrder.get(schema, "type") == "array" and
            component_reference?(KeyOrder.get(schema, "items"))))
  end

  defp strip_placeholders(args),
    do: args |> Enum.reverse() |> Enum.drop_while(&(&1 == "_")) |> Enum.reverse()

  # -- access ------------------------------------------------------------------------------

  defp get(node, key), do: KeyOrder.get(node, key)

  defp has?(node, key), do: is_map(node) and KeyOrder.has_key?(node, key)

  defp put(%OrderedObject{} = node, key, value), do: KeyOrder.put(node, key, value)
  defp put(%{} = node, key, value), do: Map.put(node, key, value)

  defp pairs(node), do: SchemaHelper.pairs(node)

  defp empty?(node), do: is_map(node) and KeyOrder.empty?(node)

  defp path_key?(node), do: has?(node, "@path") or has?(node, "path")
  defp call_key?(node), do: has?(node, "@call") or has?(node, "call")

  defp reserved(node, name) do
    if has?(node, "@" <> name), do: get(node, "@" <> name), else: get(node, name)
  end

  defp non_empty(value) when value in [nil, ""], do: nil
  defp non_empty(value), do: value

  defp truthy?(value) when is_map(value), do: not empty?(value)
  defp truthy?(value), do: value not in [nil, false, "", [], 0, 0.0]
end

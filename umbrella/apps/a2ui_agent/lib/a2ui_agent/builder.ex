defmodule A2UIAgent.Builder do
  @moduledoc """
  Builds component trees in Elixir and flattens them into the component
  lists that A2UI messages carry.

  A tree is made of component nodes (`component/2`, or the functions of
  `A2UIAgent.Builder.Basic`). A node placed in a property of another
  node becomes a component of its own, and the property holds its id:

      iex> import A2UIAgent.Builder
      iex> import A2UIAgent.Builder.Basic
      iex> tree =
      ...>   card(
      ...>     id: "account",
      ...>     child:
      ...>       column(
      ...>         children: [
      ...>           text(text: "Account overview"),
      ...>           button(child: text(text: "Details"), action: event("details"))
      ...>         ]
      ...>       )
      ...>   )
      iex> tree |> flatten() |> Enum.map(&{&1["id"], &1["component"]})
      [
        {"account__text_1", "Text"},
        {"account__text_2", "Text"},
        {"account__button_1", "Button"},
        {"account__column_1", "Column"},
        {"account", "Card"}
      ]

  Children come before their parents, so every reference points at a
  component already in the list.

  ## Ids

  The root's id is the `:root_id` option, else its own `:id`. The other
  components are named after the root: a node with an `:id` gets
  `<root>__<id>`, and a node without one gets `<root>__<name>_<n>`, its
  component name in lower case and a count per name, skipping ids the
  author gave. A root without an id, and no `:root_id`, takes such an id
  under the prefix `root`. A list of trees is flattened tree by tree;
  with a `:root_id`, the trees' roots are `<root_id>_0`, `<root_id>_1`
  and so on.

  ## Values

  Properties are given as a keyword list or a map. Atom keys are written
  in lower camel case (`validation_regexp:` becomes
  `"validationRegexp"`); string keys are written as they are. Besides
  plain JSON values and nodes, a property can hold:

    * `ref/1`, a component already on the surface, written as its id and
      never emitted;
    * `child_list/2`, children repeated over a data model list;
    * `bind/1`, a data binding;
    * `call/3`, a function call;
    * `event/2` and `action/1`, the two kinds of action;
    * `check/2`, a check rule, and `accessibility/1`, accessibility
      attributes.

  Bindings and function calls are written with the keys of the protocol
  version (`path` and `call` before v1.0, `@path` and `@call` from it).
  `nil` properties are left out.

  ## Catalogs

  With the `:catalog` option, `flatten/2` completes each component with
  the defaults its catalog schema declares for properties the node does
  not set, emits children in the order the catalog declares the
  properties holding them, and checks each component against the catalog
  (`A2UICore.Validation.Payload.validate_component/3`), raising
  `A2UICore.Error` for one the catalog rejects. This is how the
  reference SDKs' generated builders behave.

  Macros (`A2UIAgent.Macro`) can be called inside a tree; see
  `A2UIAgent.Macro.call/2`.
  """

  alias A2UIAgent.Builder.{Binding, ChildList, Component, FunctionCall, Ref}
  alias A2UIAgent.Macro
  alias A2UICore.{Catalog, Error, KeyOrder, SemVer}
  alias A2UICore.Validation.Payload

  @moduledoc since: "0.1.0"

  @typedoc "A component tree, or a list of them."
  @type tree :: Component.t() | Ref.t() | Macro.Call.t() | [tree()]

  @typedoc "Properties: a keyword list or a map."
  @type props :: keyword() | map()

  @max_depth 16

  # -- nodes and values ---------------------------------------------------------------

  @doc """
  A component node. `props` may set `:id`; see the moduledoc for keys and
  values.

      iex> A2UIAgent.Builder.component("Text", id: "title", text: "Hello").props
      [{"text", "Hello"}]
  """
  @spec component(String.t(), props()) :: Component.t()
  def component(name, props \\ []) when is_binary(name) do
    {id, props} =
      props
      |> pairs(&wire_key/1)
      |> Enum.split_with(fn {key, _value} -> key == "id" end)

    if List.keymember?(props, "component", 0),
      do: raise(ArgumentError, "the component name is the first argument, not a property")

    %Component{component: name, id: component_id(id), props: props}
  end

  defp component_id([]), do: nil
  defp component_id([{"id", id}]) when is_binary(id) or is_nil(id), do: id

  defp component_id([{"id", id}]),
    do: raise(ArgumentError, "a component id must be a string, got: #{inspect(id)}")

  @doc "A reference to a component already on the surface, by id."
  @spec ref(String.t()) :: Ref.t()
  def ref(id) when is_binary(id), do: %Ref{id: id}

  @doc """
  A data binding. An absolute path (`/user/name`) reads from the data
  model's root; a relative one (`name`) from the enclosing scope, such
  as a `child_list/2` item.
  """
  @spec bind(String.t()) :: Binding.t()
  def bind(path) when is_binary(path), do: %Binding{path: path}

  @doc """
  Children generated from the data model list at `path`: `template` is
  emitted once and repeated for each item.
  """
  @spec child_list(String.t(), Component.t() | Ref.t()) :: ChildList.t()
  def child_list(path, template) when is_binary(path),
    do: %ChildList{path: path, template: template}

  @doc """
  A call of the catalog function `name`. `args` follow the key rules of
  properties. Options: `:return_type`, written as `returnType`, and
  `:catalog_id`, the catalog the call runs in when it is not the
  surface's default, written as `catalogId` from protocol v1.0 (before
  it a call always runs in the surface's catalog, and the option is left
  out).

      iex> import A2UIAgent.Builder.Basic
      iex> text(id: "root", text: A2UIAgent.Builder.call("shout", [value: "hi"], catalog_id: "https://example.com/c.json"))
      ...> |> A2UIAgent.Builder.flatten()
      [
        %{
          "id" => "root",
          "component" => "Text",
          "text" => %{"@call" => "shout", "args" => %{"value" => "hi"}, "catalogId" => "https://example.com/c.json"}
        }
      ]
  """
  @spec call(String.t(), props(), keyword()) :: FunctionCall.t()
  def call(name, args \\ [], options \\ []) when is_binary(name) do
    %FunctionCall{
      call: name,
      args: Map.new(pairs(args, &wire_key/1)),
      return_type: options[:return_type],
      catalog_id: options[:catalog_id]
    }
  end

  @doc """
  An action that sends the event `name` to the agent, with an optional
  `context` (keys written as given).

      iex> A2UIAgent.Builder.event("save", order: "o-1")
      %{"event" => %{"name" => "save", "context" => %{"order" => "o-1"}}}
  """
  @spec event(String.t(), props() | nil) :: map()
  def event(name, context \\ nil) when is_binary(name) do
    event =
      if context == nil,
        do: %{"name" => name},
        else: %{"name" => name, "context" => Map.new(pairs(context, &to_string/1))}

    %{"event" => event}
  end

  @doc "An action that calls a client function (see `call/3`)."
  @spec action(FunctionCall.t()) :: map()
  def action(%FunctionCall{} = call), do: %{"functionCall" => call}

  @doc "A check rule: `condition` (usually a `call/3`) and the message shown when it fails."
  @spec check(term(), String.t()) :: map()
  def check(condition, message) when is_binary(message),
    do: %{"condition" => condition, "message" => message}

  @doc """
  Accessibility attributes, such as `label:` and `description:`.

      iex> A2UIAgent.Builder.accessibility(label: "Close")
      %{"label" => "Close"}
  """
  @spec accessibility(props()) :: map()
  def accessibility(attributes), do: Map.new(pairs(attributes, &wire_key/1))

  defp pairs(props, key_fun) when is_list(props) do
    Enum.map(props, fn
      {key, value} when is_atom(key) or is_binary(key) -> {key_fun.(key), value}
      other -> raise ArgumentError, "expected a keyword list or a map, got: #{inspect(other)}"
    end)
  end

  defp pairs(%{} = props, key_fun) when not is_struct(props),
    do: props |> Map.to_list() |> pairs(key_fun)

  defp pairs(other, _key_fun),
    do: raise(ArgumentError, "expected a keyword list or a map, got: #{inspect(other)}")

  defp wire_key(key) when is_binary(key), do: key
  defp wire_key(key) when is_atom(key), do: camelize(Atom.to_string(key))

  defp camelize("_" <> _rest = name), do: name

  defp camelize(name) do
    [first | rest] = String.split(name, "_")
    first <> Enum.map_join(rest, &upcase_first/1)
  end

  defp upcase_first(<<char::utf8, rest::binary>>), do: String.upcase(<<char::utf8>>) <> rest
  defp upcase_first(""), do: ""

  # -- flattening --------------------------------------------------------------------

  @doc """
  Flattens `tree` into a list of component maps, children first.

  Options:

    * `:root_id` — the root's id, and the prefix of the ids made for the
      components under it;
    * `:catalog` — complete and check components against this catalog
      (see "Catalogs" above);
    * `:validate` — with a catalog, whether to check components (default
      `true`);
    * `:version` — the protocol version whose keys bindings and function
      calls are written with (default: the catalog's, else `"v1.0"`);
    * `:macros` — the macros (`A2UIAgent.Macro`) that macro calls in the
      tree may name.

  Raises `ArgumentError` for a value that cannot be written as JSON and
  `A2UICore.Error` for a component the catalog rejects, or for macro
  calls nested deeper than #{@max_depth}.
  """
  @spec flatten(tree(), keyword()) :: [map()]
  def flatten(tree, options \\ []) do
    context = context(options)
    tree |> expand_calls(context, 0) |> flatten_tree(options[:root_id], context)
  end

  defp context(options) do
    catalog = options[:catalog]
    version = options[:version] || (catalog && catalog.protocol_version) || "v1.0"

    keys =
      if SemVer.at_least(version, "v1.0"),
        do: %{path: "@path", call: "@call"},
        else: %{path: "path", call: "call"}

    %{
      catalog: catalog,
      validate: catalog != nil and Keyword.get(options, :validate, true),
      keys: keys,
      macros: macro_table(options[:macros]),
      document: catalog && Catalog.to_json(catalog, ordered: true)
    }
  end

  defp macro_table(nil), do: %{}
  defp macro_table(%{} = table) when not is_struct(table), do: table
  defp macro_table(macros) when is_list(macros), do: Map.new(macros, &{&1.name, &1})

  defp flatten_tree(trees, root_id, context) when is_list(trees) do
    trees
    |> Enum.with_index()
    |> Enum.flat_map(fn {tree, index} ->
      flatten_tree(tree, root_id && "#{root_id}_#{index}", context)
    end)
  end

  defp flatten_tree(%Ref{}, _root_id, _context), do: []

  defp flatten_tree(%Component{} = root, root_id, context) do
    prefix = root_id || root.id || "root"
    reserved = reserve(root, prefix, %{})
    reserved = if root_id, do: Map.put(reserved, root_id, true), else: reserved
    state = %{prefix: prefix, counters: %{}, taken: reserved, components: []}

    {id, state} =
      case root_id || root.id do
        nil -> allocate(state, root.component, nil)
        id -> {id, state}
      end

    {payload, state} = dump(root, id, state, context)
    Enum.reverse([payload | state.components])
  end

  defp flatten_tree(other, _root_id, _context),
    do: raise(ArgumentError, "expected a component tree, got: #{inspect(other)}")

  # The first pass: the ids authors gave, bare and under the prefix, so
  # that made ids never take one.
  defp reserve(%Component{id: id, props: props}, prefix, reserved) do
    reserved =
      if id,
        do: reserved |> Map.put(id, true) |> Map.put("#{prefix}__#{id}", true),
        else: reserved

    Enum.reduce(props, reserved, fn {_key, value}, acc -> reserve_value(value, prefix, acc) end)
  end

  defp reserve_value(%Component{} = node, prefix, reserved), do: reserve(node, prefix, reserved)

  defp reserve_value(%ChildList{template: template}, prefix, reserved),
    do: reserve_value(template, prefix, reserved)

  defp reserve_value(%FunctionCall{args: args}, prefix, reserved),
    do: reserve_value(args, prefix, reserved)

  defp reserve_value(%{} = map, prefix, reserved) when not is_struct(map),
    do: Enum.reduce(map, reserved, fn {_key, value}, acc -> reserve_value(value, prefix, acc) end)

  defp reserve_value(list, prefix, reserved) when is_list(list),
    do: Enum.reduce(list, reserved, &reserve_value(&1, prefix, &2))

  defp reserve_value(_value, _prefix, reserved), do: reserved

  defp allocate(state, _component, preferred) when is_binary(preferred) do
    id = "#{state.prefix}__#{preferred}"
    {id, %{state | taken: Map.put(state.taken, id, true)}}
  end

  defp allocate(state, component, nil) do
    base = String.downcase(component)
    count = Map.get(state.counters, base, 0) + 1
    id = "#{state.prefix}__#{base}_#{count}"
    state = %{state | counters: Map.put(state.counters, base, count)}

    if Map.has_key?(state.taken, id),
      do: allocate(state, component, nil),
      else: {id, %{state | taken: Map.put(state.taken, id, true)}}
  end

  defp dump(%Component{} = node, id, state, context) do
    {written, state} =
      node.props
      |> in_catalog_order(node.component, context)
      |> Enum.reject(fn {_key, value} -> value == nil end)
      |> Enum.map_reduce(state, fn {key, value}, state ->
        {json, state} = write(value, state, context)
        {{key, json}, state}
      end)

    payload =
      Map.merge(
        defaults(node, context),
        Map.new([{"component", node.component}, {"id", id} | written])
      )

    check!(payload, context)
    {payload, state}
  end

  defp write(%Component{} = node, state, context) do
    {id, state} = allocate(state, node.component, node.id)
    {payload, state} = dump(node, id, state, context)
    {id, %{state | components: [payload | state.components]}}
  end

  defp write(%Ref{id: id}, state, _context), do: {id, state}

  defp write(%ChildList{path: path, template: template}, state, context) do
    {id, state} = write(template, state, context)
    {%{"path" => path, "componentId" => id}, state}
  end

  defp write(%Binding{path: path}, state, context), do: {%{context.keys.path => path}, state}

  defp write(%FunctionCall{} = call, state, context) do
    {args, state} = write(call.args, state, context)
    json = %{context.keys.call => call.call, "args" => args}
    json = if call.return_type, do: Map.put(json, "returnType", call.return_type), else: json

    if call.catalog_id && context.keys.call == "@call",
      do: {Map.put(json, "catalogId", call.catalog_id), state},
      else: {json, state}
  end

  defp write(%{} = map, state, context) when not is_struct(map) do
    {pairs, state} =
      Enum.map_reduce(map, state, fn {key, value}, state ->
        {json, state} = write(value, state, context)
        {{json_key(key), json}, state}
      end)

    {Map.new(pairs), state}
  end

  defp write(list, state, context) when is_list(list),
    do: Enum.map_reduce(list, state, &write(&1, &2, context))

  defp write(value, state, _context)
       when is_binary(value) or is_number(value) or is_boolean(value) or is_nil(value),
       do: {value, state}

  defp write(value, state, _context) when is_atom(value), do: {Atom.to_string(value), state}

  defp write(value, _state, _context),
    do: raise(ArgumentError, "cannot write #{inspect(value)} as JSON")

  defp json_key(key) when is_binary(key), do: key
  defp json_key(key) when is_atom(key), do: Atom.to_string(key)

  defp json_key(key),
    do: raise(ArgumentError, "cannot write #{inspect(key)} as a JSON object key")

  # -- catalogs ----------------------------------------------------------------------

  defp in_catalog_order(props, _component, %{document: nil}), do: props

  defp in_catalog_order(props, component, context) do
    index =
      component
      |> property_schemas(context)
      |> Enum.with_index()
      |> Map.new(fn {{name, _schema}, index} -> {name, index} end)

    Enum.sort_by(props, fn {key, _value} -> Map.get(index, key, map_size(index)) end)
  end

  defp defaults(_node, %{document: nil}), do: %{}

  defp defaults(%Component{component: component, props: props}, context) do
    for {name, schema} <- property_schemas(component, context),
        KeyOrder.has_key?(schema, "default"),
        not List.keymember?(props, name, 0),
        into: %{},
        do: {name, KeyOrder.to_plain(KeyOrder.get(schema, "default"))}
  end

  # The properties a component's schema declares, in document order:
  # its own and those of the `allOf` members, following references
  # into the catalog's `$defs`.
  defp property_schemas(component, context) do
    case context.document |> KeyOrder.get("components") |> KeyOrder.get(component) do
      nil -> []
      schema -> schema_properties(schema, KeyOrder.get(context.document, "$defs"), 0)
    end
  end

  defp schema_properties(_schema, _defs, depth) when depth > 8, do: []

  defp schema_properties(schema, defs, depth) do
    case KeyOrder.get(schema, "$ref") do
      "#/$defs/" <> name ->
        schema_properties(KeyOrder.get(defs, name), defs, depth + 1)

      _other ->
        members = KeyOrder.get(schema, "allOf")
        members = if is_list(members), do: members, else: []

        Enum.flat_map(members, &schema_properties(&1, defs, depth + 1)) ++
          entries(KeyOrder.get(schema, "properties"))
    end
  end

  defp entries(%{} = properties), do: Enum.to_list(properties)
  defp entries(_other), do: []

  defp check!(_payload, %{validate: false}), do: :ok

  defp check!(payload, context) do
    if Map.has_key?(context.macros, payload["component"]) do
      :ok
    else
      case Payload.validate_component(context.catalog, payload) do
        :ok -> :ok
        {:error, %Error{} = error} -> raise error
      end
    end
  end

  # -- macro calls -------------------------------------------------------------------

  defp expand_calls(%Macro.Call{} = call, _context, depth) when depth > @max_depth do
    raise Error.new(
            :recursion,
            "RECURSION_LIMIT",
            "Macro expansion exceeded maximum recursion depth of #{@max_depth} " <>
              "(calling #{inspect(macro_name(call.macro))})."
          )
  end

  defp expand_calls(%Macro.Call{macro: macro, args: args}, context, depth) do
    macro
    |> resolve_macro(context)
    |> Macro.build(args)
    |> expand_calls(context, depth + 1)
  end

  defp expand_calls(%Component{props: props} = node, context, depth),
    do: %{
      node
      | props: Enum.map(props, fn {key, value} -> {key, expand_calls(value, context, depth)} end)
    }

  defp expand_calls(%ChildList{template: template} = list, context, depth),
    do: %{list | template: expand_calls(template, context, depth)}

  defp expand_calls(%FunctionCall{args: args} = call, context, depth),
    do: %{call | args: expand_calls(args, context, depth)}

  defp expand_calls(%{} = map, context, depth) when not is_struct(map),
    do: Map.new(map, fn {key, value} -> {key, expand_calls(value, context, depth)} end)

  defp expand_calls(list, context, depth) when is_list(list),
    do: Enum.map(list, &expand_calls(&1, context, depth))

  defp expand_calls(value, _context, _depth), do: value

  defp resolve_macro(%Macro{} = macro, _context), do: macro

  defp resolve_macro(name, context) when is_binary(name) do
    case Map.fetch(context.macros, name) do
      {:ok, macro} -> macro
      :error -> raise ArgumentError, "no macro named #{inspect(name)} was given (`:macros`)"
    end
  end

  defp macro_name(%Macro{name: name}), do: name
  defp macro_name(name), do: name

  # -- messages ----------------------------------------------------------------------

  @doc """
  The messages that put `tree` on a surface: a `createSurface` when
  `:catalog_id` is given, an `updateComponents` with the flattened
  components, and an `updateDataModel` for each `:data_model` entry.

  Options: `:surface_id` (required), `:catalog_id`, `:data_model` (path
  and value pairs, or a map), `:version` (the version messages state;
  default: the catalog's, else `"v1.0"`), and the options of
  `flatten/2`.

      iex> import A2UIAgent.Builder.Basic
      iex> A2UIAgent.Builder.messages(text(id: "root", text: "Hi"), surface_id: "s", version: "v0.9")
      [
        %{
          "version" => "v0.9",
          "updateComponents" => %{
            "surfaceId" => "s",
            "components" => [%{"id" => "root", "component" => "Text", "text" => "Hi"}]
          }
        }
      ]
  """
  @spec messages(tree(), keyword()) :: [map()]
  def messages(tree, options) do
    surface_id = Keyword.fetch!(options, :surface_id)
    catalog = options[:catalog]
    version = options[:version] || (catalog && catalog.protocol_version) || "v1.0"
    components = flatten(tree, Keyword.put(options, :version, version))

    create =
      case options[:catalog_id] do
        nil ->
          []

        catalog_id ->
          [%{"createSurface" => %{"surfaceId" => surface_id, "catalogId" => catalog_id}}]
      end

    update = [%{"updateComponents" => %{"surfaceId" => surface_id, "components" => components}}]

    data =
      for {path, value} <- Enum.to_list(options[:data_model] || []) do
        %{"updateDataModel" => %{"surfaceId" => surface_id, "path" => path, "value" => value}}
      end

    Enum.map(create ++ update ++ data, &Map.put(&1, "version", version))
  end
end

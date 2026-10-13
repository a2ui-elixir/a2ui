defmodule A2UICore.Resolution.NodeResolver do
  @moduledoc """
  Resolves a surface's flat component dictionary into a tree of
  `A2UICore.Resolution.Node`s.

  Child references become nodes, collection templates become one node
  per item (each in its item's data scope), components that have not
  arrived yet become `:pending` placeholders that are replaced when
  their definition does, and a component referenced by one of its own
  descendants is cut with a `:cyclic` placeholder.

  The resolver is plain data. It does not observe anything: after the
  surface changed, hand the new surface to `update/2` and read what
  happened from the notifications it returns.

      {resolver, notifications} = NodeResolver.new(surface)
      surface = Surface.put_components(surface, components)
      {resolver, notifications} = NodeResolver.update(resolver, surface)

  ## Identity

  A position is identified by the edge that leads to it (the parent
  position, the property, and the component and data path it points at).
  While the edge keeps leading to the same kind of node, the node keeps
  its `ref`; only its props change. A node is replaced — and the old
  one destroyed — when the component behind the edge appears, goes away
  or changes type, when a sibling ordinal shifts, or when its parent is
  destroyed.

  ## Notifications

    * `{:node_created, ref}` — a new position is mounted;
    * `{:node_updated, ref}` — a node that was already mounted now has
      different props (reported once per `update/2`, whatever number of
      properties changed);
    * `{:node_destroyed, ref}` — a mounted node is gone; reported once;
    * `{:error | :warning, payload}` — a diagnostic (an unknown component
      type, a cyclic reference, a binding that does not resolve), reported
      when the condition appears and again only after it went away.

  `write/4` and `invoke/5` are the interaction half: they say which path
  a write reaches and which events and calls an action produces, from
  the surface as it is *now*.
  """

  alias A2UICore.{Catalog, Error}
  alias A2UICore.Catalog.RefSpec
  alias A2UICore.Resolution.{Action, Binder, Binding, DataContext, Node}
  alias A2UICore.State.{Components, Surface}

  @moduledoc since: "0.1.0"

  defstruct surface_id: nil,
            root: nil,
            nodes: %{},
            edges: %{},
            next_ref: 1,
            reported: MapSet.new(),
            disposed?: false

  @type t :: %__MODULE__{
          surface_id: String.t() | nil,
          root: pos_integer() | nil,
          nodes: %{optional(pos_integer()) => Node.t()},
          edges: %{optional(String.t()) => pos_integer()},
          next_ref: pos_integer(),
          reported: MapSet.t(),
          disposed?: boolean()
        }

  @type notification ::
          {:node_created, pos_integer()}
          | {:node_updated, pos_integer()}
          | {:node_destroyed, pos_integer()}
          | {:error | :warning, map()}

  @type interaction ::
          {:action_event, map()}
          | {:error | :warning, map()}

  @id_escapes %{"~" => "~0", "#" => "~1", "[" => "~2", "]" => "~3", ">" => "~4", "@" => "~5"}

  # -- lifecycle ----------------------------------------------------------------

  @doc """
  Resolves `surface` from scratch.
  """
  @spec new(Surface.t()) :: {t(), [notification()]}
  def new(%Surface{id: id} = surface), do: update(%__MODULE__{surface_id: id}, surface)

  @doc """
  Reconciles the tree with `surface`'s current components and data.

  Returns the new resolver and the notifications, in the order things
  were found (creations and updates, then destructions).
  """
  @spec update(t(), Surface.t()) :: {t(), [notification()]}
  def update(%__MODULE__{disposed?: true} = resolver, _surface), do: {resolver, []}

  def update(%__MODULE__{} = previous, %Surface{} = surface) do
    build = %{
      surface: surface,
      previous: previous,
      next_ref: previous.next_ref,
      nodes: %{},
      edges: %{},
      conditions: MapSet.new(),
      notes: []
    }

    {build, root} = build_root(build)

    destroyed =
      for {ref, _node} <- Enum.sort(previous.nodes),
          not Map.has_key?(build.nodes, ref),
          do: {:node_destroyed, ref}

    resolver = %{
      previous
      | root: root,
        nodes: build.nodes,
        edges: build.edges,
        next_ref: build.next_ref,
        reported: build.conditions
    }

    {resolver, Enum.reverse(build.notes) ++ destroyed}
  end

  @doc """
  Destroys every node and stops the resolver; further updates do
  nothing. Idempotent.
  """
  @spec dispose(t()) :: {t(), [notification()]}
  def dispose(%__MODULE__{disposed?: true} = resolver), do: {resolver, []}

  def dispose(%__MODULE__{nodes: nodes} = resolver) do
    destroyed = for {ref, _node} <- Enum.sort(nodes), do: {:node_destroyed, ref}

    {%{resolver | root: nil, nodes: %{}, edges: %{}, reported: MapSet.new(), disposed?: true},
     destroyed}
  end

  # -- inspection ---------------------------------------------------------------

  @doc "The root node, or `nil` while the root component is missing."
  @spec root(t()) :: Node.t() | nil
  def root(%__MODULE__{root: nil}), do: nil
  def root(%__MODULE__{root: ref, nodes: nodes}), do: Map.get(nodes, ref)

  @doc "The mounted node with `ref`, or `nil`."
  @spec node(t(), pos_integer()) :: Node.t() | nil
  def node(%__MODULE__{nodes: nodes}, ref), do: Map.get(nodes, ref)

  @doc "Number of mounted nodes, placeholders included."
  @spec count(t()) :: non_neg_integer()
  def count(%__MODULE__{nodes: nodes}), do: map_size(nodes)

  @doc """
  The mounted nodes by position: `"root"`, `"root/child"`,
  `"root/children/0"`, `"root/tabs/1/child"`. Positions describe where a
  node sits in the tree; they are not identities.
  """
  @spec positions(t()) :: %{optional(String.t()) => Node.t()}
  def positions(%__MODULE__{root: nil}), do: %{}
  def positions(%__MODULE__{root: root} = resolver), do: collect_node(resolver, root, "root", %{})

  defp collect_node(resolver, ref, path, acc) do
    node = Map.fetch!(resolver.nodes, ref)
    collect_value(resolver, node.props, path, Map.put(acc, path, node))
  end

  defp collect_value(resolver, {:node, ref}, path, acc),
    do: collect_node(resolver, ref, path, acc)

  defp collect_value(_resolver, %Binding{}, _path, acc), do: acc
  defp collect_value(_resolver, %Action{}, _path, acc), do: acc

  defp collect_value(resolver, list, path, acc) when is_list(list) do
    list
    |> Enum.with_index()
    |> Enum.reduce(acc, fn {item, index}, acc ->
      collect_value(resolver, item, "#{path}/#{index}", acc)
    end)
  end

  defp collect_value(resolver, map, path, acc) when is_map(map) do
    Enum.reduce(map, acc, fn {key, item}, acc ->
      collect_value(resolver, item, "#{path}/#{key}", acc)
    end)
  end

  defp collect_value(_resolver, _value, _path, acc), do: acc

  # -- interaction --------------------------------------------------------------

  @doc """
  What a write to `property` of node `ref` changes: `{:ok, path, value}`
  when the property is a binding to a data path, an error otherwise.
  Apply it with `A2UICore.State.Surface.set_data/3` and `update/2`.
  """
  @spec write(t(), pos_integer(), String.t(), term()) ::
          {:ok, String.t(), term()} | {:error, Error.t()}
  def write(%__MODULE__{} = resolver, ref, property, value) do
    with {:ok, node} <- fetch_node(resolver, ref) do
      case Map.get(node.props, property) do
        %Binding{path: path} when is_binary(path) ->
          {:ok, path, value}

        _not_writable ->
          {:error,
           Error.new(
             :state,
             "NOT_WRITABLE",
             "Property '#{property}' of component '#{node.component_id}' is not a writable binding."
           )}
      end
    end
  end

  @doc """
  Invokes the action in `property` of node `ref`, evaluating its dynamic
  parts against `surface` as it is now.

  An event action yields `{:action_event, event}` (see
  `A2UICore.State.Surface.dispatch_action/4`); a function-call action
  runs the catalog function and yields no event. Resolution problems
  come back as `{:error, payload}` / `{:warning, payload}` entries.
  """
  @spec invoke(t(), Surface.t(), pos_integer(), String.t(), DateTime.t()) ::
          {:ok, [interaction()]} | {:error, Error.t()}
  def invoke(resolver, surface, ref, property, now \\ DateTime.utc_now())

  def invoke(%__MODULE__{} = resolver, %Surface{} = surface, ref, property, now) do
    with {:ok, node} <- fetch_node(resolver, ref) do
      case Map.get(node.props, property) do
        %Action{definition: definition} ->
          {:ok, run_action(surface, node, definition, now)}

        _not_an_action ->
          {:error,
           Error.new(
             :state,
             "NOT_AN_ACTION",
             "Property '#{property}' of component '#{node.component_id}' is not an action."
           )}
      end
    end
  end

  defp run_action(surface, node, definition, now) do
    context = DataContext.for_surface(surface, path: node.data_path)
    {resolved, effects} = DataContext.resolve_action(context, definition)

    case Surface.dispatch_action(surface, resolved, node.component_id, now) do
      nil -> effects
      event -> [{:action_event, event} | effects]
    end
  end

  defp fetch_node(%__MODULE__{nodes: nodes}, ref) do
    case Map.fetch(nodes, ref) do
      {:ok, node} ->
        {:ok, node}

      :error ->
        {:error, Error.new(:state, "NODE_NOT_FOUND", "No mounted node with reference #{ref}.")}
    end
  end

  # -- building -----------------------------------------------------------------

  defp build_root(%{surface: surface} = build) do
    root_id = surface.root_id || "root"

    case Components.get(surface.components, root_id) do
      nil ->
        {build, nil}

      _component ->
        escaped = escape(root_id)

        build_edge(build, %{
          component_id: root_id,
          data_path: "/",
          edge: ">#{escaped}>#{escaped}@/",
          parent: nil,
          occurrence: 1,
          ancestors: []
        })
    end
  end

  # Builds the node an edge leads to; returns the build and its `ref`.
  defp build_edge(build, edge) do
    model = Components.get(build.surface.components, edge.component_id)
    catalog = model && component_catalog(build.surface, model)
    kind = node_kind(edge, model, catalog)
    existing = existing_node(build.previous, edge.edge)

    {build, node, retained?} = claim(build, edge, model, kind, existing)

    {build, node} =
      case kind do
        :resolved -> resolve_children(build, node, model, catalog, edge.ancestors)
        other -> {report_placeholder(build, other, edge, model, catalog), node}
      end

    build = mount(build, node, retained? && existing)
    {build, node.ref}
  end

  defp component_catalog(surface, model) do
    Map.get(surface.catalogs, model.catalog_id) || Surface.default_catalog(surface)
  end

  defp node_kind(edge, model, catalog) do
    cond do
      {edge.component_id, edge.data_path} in edge.ancestors -> :cyclic
      model == nil -> :pending
      catalog != nil and Catalog.get_component(catalog, model.type) != nil -> :resolved
      true -> :unknown_type
    end
  end

  defp existing_node(%__MODULE__{edges: edges, nodes: nodes}, edge_key) do
    with ref when is_integer(ref) <- Map.get(edges, edge_key), do: Map.get(nodes, ref)
  end

  # The node is kept when the edge still leads to the same kind of node;
  # otherwise a fresh one takes the position.
  defp claim(build, edge, model, kind, existing) do
    if reusable?(existing, edge, model, kind) do
      {build, %Node{existing | props: %{}, children: []}, true}
    else
      ref = build.next_ref

      node = %Node{
        ref: ref,
        instance_id: instance_id(edge.component_id, edge.data_path, edge.occurrence),
        component_id: edge.component_id,
        type: model && model.type,
        state: kind,
        data_path: edge.data_path,
        parent: edge.parent,
        edge: edge.edge,
        catalog_id: model && model.catalog_id,
        occurrence: edge.occurrence
      }

      {%{build | next_ref: ref + 1}, node, false}
    end
  end

  defp reusable?(nil, _edge, _model, _kind), do: false

  defp reusable?(%Node{} = existing, edge, model, kind) do
    existing.component_id == edge.component_id and existing.data_path == edge.data_path and
      existing.occurrence == edge.occurrence and existing.state == kind and
      (kind in [:pending, :cyclic] or existing.type == model.type)
  end

  defp mount(build, %Node{} = node, previous) do
    note =
      case previous do
        false -> {:node_created, node.ref}
        %Node{props: props} when props == node.props -> nil
        %Node{} -> {:node_updated, node.ref}
      end

    build = %{
      build
      | nodes: Map.put(build.nodes, node.ref, node),
        edges: Map.put(build.edges, node.edge, node.ref)
    }

    if note, do: %{build | notes: [note | build.notes]}, else: build
  end

  # -- diagnostics --------------------------------------------------------------

  defp report_placeholder(build, :unknown_type, edge, model, catalog) do
    report(
      build,
      {"UNKNOWN_COMPONENT_TYPE", edge.component_id, edge.data_path},
      %{
        code: "UNKNOWN_COMPONENT_TYPE",
        message:
          "Component '#{edge.component_id}' has type '#{model.type}', which is not in " <>
            "catalog '#{catalog && catalog.catalog_id}'.",
        component_id: edge.component_id,
        data_path: edge.data_path
      },
      :error
    )
  end

  defp report_placeholder(build, :cyclic, edge, _model, _catalog) do
    report(
      build,
      {"CYCLIC_REFERENCE", edge.component_id, edge.data_path},
      %{
        code: "CYCLIC_REFERENCE",
        message:
          "Component '#{edge.component_id}' at '#{edge.data_path}' is referenced by one of " <>
            "its own descendants; rendering a placeholder instead.",
        component_id: edge.component_id,
        data_path: edge.data_path
      },
      :error
    )
  end

  defp report_placeholder(build, _kind, _edge, _model, _catalog), do: build

  # A condition is reported when it appears and not again while it lasts.
  defp report(build, key, payload, level) do
    build = %{build | conditions: MapSet.put(build.conditions, key)}

    if MapSet.member?(build.previous.reported, key),
      do: build,
      else: %{build | notes: [{level, payload} | build.notes]}
  end

  defp report_effect(build, node, {level, payload}) do
    key = {payload[:code], node.component_id, node.data_path, payload[:path] || payload[:message]}

    located = Map.merge(payload, %{component_id: node.component_id, data_path: node.data_path})
    report(build, key, located, level)
  end

  # -- props and children -------------------------------------------------------

  defp resolve_children(build, %Node{} = node, model, catalog, ancestors) do
    context = DataContext.for_surface(build.surface, path: node.data_path)
    {bound, effects} = Binder.bind(context, model, catalog, wrap: true)
    build = Enum.reduce(effects, build, &report_effect(&2, node, &1))

    state = %{
      build: build,
      context: context,
      node: node,
      ancestors: [{node.component_id, node.data_path} | ancestors],
      occurrences: %{},
      children: []
    }

    {props, state} =
      case Catalog.ref_spec(catalog, model.type) do
        %RefSpec{} = spec -> substitute(bound, spec, state)
        nil -> {bound, state}
      end

    {state.build, %Node{node | props: props, children: Enum.reverse(state.children)}}
  end

  defp substitute(props, %RefSpec{} = spec, state) do
    keys = spec.single |> MapSet.union(spec.list) |> MapSet.to_list() |> Enum.sort()

    Enum.reduce(keys, {props, state}, fn key, {props, state} ->
      case Map.fetch(props, key) do
        {:ok, value} ->
          {value, state} = substitute_value(spec, key, value, state)
          {Map.put(props, key, value), state}

        :error ->
          {props, state}
      end
    end)
  end

  defp substitute_value(spec, key, value, state) do
    cond do
      MapSet.member?(spec.list, key) -> substitute_list(spec, key, value, state)
      is_binary(value) and value != "" -> child(state, escape(key), value, state.node.data_path)
      true -> {value, state}
    end
  end

  defp substitute_list(_spec, key, value, state) when is_binary(value) and value != "",
    do: child(state, escape(key), value, state.node.data_path)

  defp substitute_list(spec, key, value, state) when is_list(value) do
    nested = Map.get(spec.nested, key)

    {items, state} =
      value
      |> Enum.with_index()
      |> Enum.reduce({[], state}, fn {item, index}, {items, state} ->
        {resolved, state} = list_item(escape(key), index, item, nested, state)
        {Enum.reverse(resolved, items), state}
      end)

    {Enum.reverse(items), state}
  end

  defp substitute_list(_spec, key, %{} = value, state), do: template(state, escape(key), value)
  defp substitute_list(_spec, _key, value, state), do: {value, state}

  # One entry of a list property: a component id, a template, a
  # `{componentId}` object, or an object with child slots.
  defp list_item(key, index, item, _nested, state) when is_binary(item) and item != "" do
    {ref, state} = child(state, "#{key}[#{index}]", item, state.node.data_path)
    {[ref], state}
  end

  defp list_item(key, index, %{"componentId" => id} = item, _nested, state)
       when is_binary(id) and id != "" do
    if is_binary(item["path"]) do
      template(state, "#{key}[#{index}]", item)
    else
      {ref, state} = child(state, "#{key}[#{index}]", id, state.node.data_path)
      {[ref], state}
    end
  end

  defp list_item(key, index, %{} = item, nested, state) when not is_nil(nested) do
    slots = nested |> MapSet.to_list() |> Enum.sort()

    {item, state} =
      Enum.reduce(slots, {item, state}, fn slot, {item, state} ->
        case item do
          %{^slot => id} when is_binary(id) and id != "" ->
            {ref, state} =
              child(state, "#{key}[#{index}].#{escape(slot)}", id, state.node.data_path)

            {Map.put(item, slot, ref), state}

          _no_child ->
            {item, state}
        end
      end)

    {[item], state}
  end

  defp list_item(_key, _index, item, _nested, state), do: {[item], state}

  # `{componentId, path}`: one child per element of the array at `path`.
  defp template(state, slot, %{"componentId" => id, "path" => path})
       when is_binary(id) and id != "" and is_binary(path) do
    absolute = DataContext.resolve_path(state.context, path)

    case Surface.get_data(state.build.surface, absolute) do
      {:ok, items} when is_list(items) ->
        base = String.trim_trailing(absolute, "/")

        {refs, state} =
          items
          |> Enum.with_index()
          |> Enum.reduce({[], state}, fn {_item, index}, {refs, state} ->
            {ref, state} = child(state, "#{slot}[#{index}]", id, "#{base}/#{index}")
            {[ref | refs], state}
          end)

        {Enum.reverse(refs), state}

      _not_a_list ->
        {[], state}
    end
  end

  defp template(state, _slot, value), do: {value, state}

  defp child(state, slot, component_id, data_path) do
    occurrence_key = "#{escape(component_id)}@#{escape(data_path)}"
    occurrence = Map.get(state.occurrences, occurrence_key, 0) + 1

    edge = %{
      component_id: component_id,
      data_path: data_path,
      edge: "#{state.node.edge}>#{slot}>#{occurrence_key}",
      parent: state.node.ref,
      occurrence: occurrence,
      ancestors: state.ancestors
    }

    {build, ref} = build_edge(state.build, edge)

    state = %{
      state
      | build: build,
        occurrences: Map.put(state.occurrences, occurrence_key, occurrence),
        children: [ref | state.children]
    }

    {{:node, ref}, state}
  end

  # -- instance ids -------------------------------------------------------------

  # `~`, `#`, `[`, `]`, `>` and `@` carry meaning in composed ids; they
  # are escaped so different tuples cannot collide.
  defp escape(part), do: String.replace(part, Map.keys(@id_escapes), &Map.fetch!(@id_escapes, &1))

  defp instance_id(component_id, data_path, occurrence) do
    trimmed =
      case String.trim_trailing(data_path, "/") do
        "" -> "/"
        path -> path
      end

    base =
      if data_path == "/",
        do: escape(component_id),
        else: "#{escape(component_id)}-[#{escape(trimmed)}]"

    if occurrence > 1, do: "#{base}##{occurrence}", else: base
  end
end

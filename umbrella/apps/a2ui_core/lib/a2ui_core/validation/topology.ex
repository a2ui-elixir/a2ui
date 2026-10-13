defmodule A2UICore.Validation.Topology do
  @moduledoc """
  Component-graph validation: root presence, dangling references,
  self-references, cycles, depth, unreachable components, and catalog
  composition constraints.

  All checks work on an `A2UICore.State.Components` set and an
  `info_fun` — a function from a component to what its catalog knows
  about the type (`t:A2UICore.State.Component.info/0`: the child
  `RefSpec`, `allowed_parents`, `allowed_children`; `nil` for an unknown
  type). They are pure and return `:ok` / `{:ok, reachable}` or
  `{:error, %A2UICore.Error{}}`.

  Error categories follow the reference: a missing root, a dangling
  reference or an unreachable component is `:integrity`; a
  self-reference, a cycle or exceeding the depth limit is `:recursion`;
  a composition-constraint violation is `:validation`
  (`UNALLOWED_PARENT` / `UNALLOWED_CHILD`). Messages carry both the
  Python and TypeScript SDK phrasings, because conformance matches on
  message substrings.

  Components are visited in sorted id order, so where a graph has
  several violations the one reported is deterministic (the reference
  follows insertion order).
  """

  alias A2UICore.Error
  alias A2UICore.Error.Detail
  alias A2UICore.State.{Component, Components}
  alias A2UICore.Validation.Config

  @moduledoc since: "0.1.0"

  @max_global_depth 50

  @type info_fun :: (Component.t() -> Component.info() | nil)

  @doc """
  Full topology validation: integrity, then reachability/cycles/depth.
  Empty component sets are valid.
  """
  @spec validate(Components.t(), info_fun(), Config.t()) :: :ok | {:error, Error.t()}
  def validate(%Components{} = components, info_fun, %Config{} = config) do
    if Components.size(components) == 0 do
      :ok
    else
      with :ok <- validate_integrity(components, info_fun, config),
           {:ok, _visited} <- analyze(components, info_fun, config) do
        :ok
      end
    end
  end

  @doc """
  Checks that the root exists (unless `allow_missing_root`) and that
  every referenced component exists (unless `allow_dangling_references`).
  """
  @spec validate_integrity(Components.t(), info_fun(), Config.t()) :: :ok | {:error, Error.t()}
  def validate_integrity(%Components{} = components, info_fun, %Config{} = config) do
    ids = Components.ids(components)

    cond do
      !config.allow_missing_root and config.root_id not in ids ->
        integrity("Missing root component: No component has id='#{config.root_id}'", nil)

      config.allow_dangling_references ->
        :ok

      true ->
        known = MapSet.new(ids)
        components |> Components.to_list() |> find_dangling(components, info_fun, known)
    end
  end

  defp find_dangling(list, components, info_fun, known),
    do: Enum.find_value(list, :ok, &first_dangling(&1, components, info_fun, known))

  defp first_dangling(component, components, info_fun, known) do
    Enum.find_value(references(component, info_fun, known), fn {ref, field} ->
      if Components.has?(components, ref), do: nil, else: dangling(component.id, ref, field)
    end)
  end

  defp dangling(id, ref, field) do
    integrity(
      "Dangling reference: Component '#{id}' references non-existent component '#{ref}' " <>
        "in field '#{field}' (Dangling reference '#{ref}' in component '#{id}')",
      id
    )
  end

  @doc """
  Checks self-references, cycles and the depth limit, and (unless
  `allow_orphan_components`) that every component is reachable from the
  root. Returns the set of reachable ids.
  """
  @spec analyze(Components.t(), info_fun(), Config.t()) ::
          {:ok, MapSet.t(String.t())} | {:error, Error.t()}
  def analyze(%Components{} = components, info_fun, %Config{} = config) do
    ids = Components.ids(components)
    all_ids = MapSet.new(ids)
    max_depth = config.max_depth || @max_global_depth

    with {:ok, adjacency} <- adjacency(components, info_fun, all_ids) do
      if config.allow_missing_root do
        traverse_all(ids, adjacency, all_ids, max_depth)
      else
        traverse_from_root(ids, adjacency, all_ids, max_depth, config)
      end
    end
  end

  defp adjacency(components, info_fun, known) do
    Enum.reduce_while(Components.to_list(components), {:ok, %{}}, fn component, {:ok, acc} ->
      case adjacency_entry(component, info_fun, known) do
        {:ok, refs} -> {:cont, {:ok, Map.put(acc, component.id, refs)}}
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  defp adjacency_entry(component, info_fun, known) do
    refs = references(component, info_fun, known)

    case Enum.find(refs, fn {ref, _field} -> ref == component.id end) do
      {_ref, field} ->
        recursion(
          "Circular reference detected: Component '#{component.id}' references itself " <>
            "in field '#{field}' (Self-reference detected)",
          component.id
        )

      nil ->
        {:ok, Enum.map(refs, &elem(&1, 0))}
    end
  end

  defp traverse_all(ids, adjacency, all_ids, max_depth) do
    Enum.reduce_while(ids, {:ok, MapSet.new()}, fn id, {:ok, visited} ->
      case visit_from(id, visited, adjacency, all_ids, max_depth) do
        {:ok, visited} -> {:cont, {:ok, visited}}
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  defp visit_from(id, visited, adjacency, all_ids, max_depth) do
    if MapSet.member?(visited, id) do
      {:ok, visited}
    else
      state = {visited, MapSet.new()}

      with {:ok, {visited, _stack}} <- dfs(id, 0, adjacency, all_ids, max_depth, state) do
        {:ok, visited}
      end
    end
  end

  defp traverse_from_root(ids, adjacency, all_ids, max_depth, config) do
    with {:ok, visited} <- visit_root(config.root_id, adjacency, all_ids, max_depth) do
      orphans = Enum.reject(ids, &MapSet.member?(visited, &1))

      case orphans do
        [orphan | _] when not config.allow_orphan_components ->
          integrity(
            "Component '#{orphan}' is not reachable from '#{config.root_id}' " <>
              "(Orphaned component '#{orphan}' is not reachable from root)",
            orphan
          )

        _ ->
          {:ok, visited}
      end
    end
  end

  defp visit_root(root_id, adjacency, all_ids, max_depth) do
    if MapSet.member?(all_ids, root_id) do
      case dfs(root_id, 0, adjacency, all_ids, max_depth, {MapSet.new(), MapSet.new()}) do
        {:ok, {visited, _stack}} -> {:ok, visited}
        {:error, _} = error -> error
      end
    else
      {:ok, MapSet.new()}
    end
  end

  defp dfs(_node, depth, _adjacency, _all_ids, max_depth, _state) when depth > max_depth do
    recursion("Global recursion limit exceeded: logical depth > #{max_depth}", nil)
  end

  defp dfs(node, depth, adjacency, all_ids, max_depth, {visited, stack}) do
    state = {MapSet.put(visited, node), MapSet.put(stack, node)}

    adjacency
    |> Map.get(node, [])
    |> Enum.reduce_while({:ok, state}, fn neighbor, {:ok, state} ->
      case visit_neighbor(neighbor, depth, adjacency, all_ids, max_depth, state) do
        {:ok, _state} = ok -> {:cont, ok}
        {:error, _} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, {visited, stack}} -> {:ok, {visited, MapSet.delete(stack, node)}}
      {:error, _} = error -> error
    end
  end

  # One edge of the depth-first walk. The returned stack is the caller's:
  # a neighbor is on the stack only while its own subtree is being walked.
  defp visit_neighbor(neighbor, depth, adjacency, all_ids, max_depth, {visited, stack} = state) do
    cond do
      !MapSet.member?(all_ids, neighbor) ->
        {:ok, state}

      !MapSet.member?(visited, neighbor) ->
        with {:ok, {visited, _inner}} <-
               dfs(neighbor, depth + 1, adjacency, all_ids, max_depth, state) do
          {:ok, {visited, stack}}
        end

      MapSet.member?(stack, neighbor) ->
        recursion("Circular reference detected involving component '#{neighbor}'", neighbor)

      true ->
        {:ok, state}
    end
  end

  @doc """
  Checks catalog `allowedParents` / `allowedChildren` constraints. A
  component constrained by `allowed_parents` that no component
  references is treated as a child of the surface itself.
  """
  @spec validate_composition(Components.t(), info_fun()) :: :ok | {:error, Error.t()}
  def validate_composition(%Components{} = components, info_fun) do
    list = Components.to_list(components)
    types = Map.new(list, &{&1.id, &1.type})

    children =
      Map.new(list, fn c -> {c.id, c |> references(info_fun, nil) |> Enum.map(&elem(&1, 0))} end)

    parents =
      Enum.reduce(list, %{}, fn parent, acc ->
        Enum.reduce(Map.fetch!(children, parent.id), acc, fn child_id, acc ->
          Map.put(acc, child_id, {parent.id, parent.type})
        end)
      end)

    Enum.find_value(list, :ok, fn component ->
      info = info_fun.(component) || %{}

      check_parent(component, info[:allowed_parents], parents) ||
        check_children(component, info[:allowed_children], children, types)
    end)
  end

  defp check_parent(_component, allowed, _parents) when allowed in [nil, []], do: nil

  defp check_parent(component, allowed, parents) do
    {parent_id, parent_type} = Map.get(parents, component.id, {"Surface", "Surface"})

    if parent_type in allowed do
      nil
    else
      composition_error(
        component.id,
        "UNALLOWED_PARENT",
        "Component '#{component.id}' (#{component.type}) cannot be placed under parent " <>
          "'#{parent_id}' (#{parent_type}). Allowed parents: #{py_list(allowed)}."
      )
    end
  end

  defp check_children(_component, allowed, _children, _types) when allowed in [nil, []], do: nil

  defp check_children(component, allowed, children, types) do
    Enum.find_value(Map.get(children, component.id, []), fn child_id ->
      child_type = Map.get(types, child_id)

      if child_type == nil or child_type in allowed do
        nil
      else
        composition_error(
          component.id,
          "UNALLOWED_CHILD",
          "Component '#{component.id}' (#{component.type}) cannot contain child " <>
            "'#{child_id}' (#{child_type}). Allowed children: #{py_list(allowed)}."
        )
      end
    end)
  end

  # Python-style list rendering, which the conformance messages use.
  defp py_list(items), do: "[" <> Enum.map_join(items, ", ", &"'#{&1}'") <> "]"

  # -- helpers -------------------------------------------------------------------

  # `known` is the set of component ids on the surface (value inspection
  # of the fallback analysis uses it); composition checks pass `nil`.
  defp references(component, info_fun, known) do
    spec =
      case info_fun.(component) do
        %{ref_spec: spec} -> spec
        _no_catalog_info -> nil
      end

    Component.child_references(component, spec, known)
  end

  defp integrity(message, id), do: failure(:integrity, "INTEGRITY_ERROR", message, id)
  defp recursion(message, id), do: failure(:recursion, "RECURSION_LIMIT", message, id)

  defp failure(category, code, message, id) do
    path = if id, do: "components.#{id}"

    {:error,
     Error.new(category, code, message, path: path, details: [detail(code, message, path)])}
  end

  defp composition_error(id, code, message) do
    path = "components.#{id}"

    {:error,
     Error.new(:validation, code, message, path: path, details: [detail(code, message, path)])}
  end

  defp detail(code, message, path), do: Detail.new(code, message, path)
end

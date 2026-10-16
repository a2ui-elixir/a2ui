defmodule A2UICore.Catalog.Refs do
  @moduledoc """
  `$ref` handling for catalog documents.

  A catalog document references three kinds of target:

    * the protocol's common types, as `common_types.json#/$defs/X` (or a
      path ending in `/common_types.json`);
    * its own definitions, as `#/…` or through a document named
      `catalog.json`;
    * a **peer catalog** it holds, as `<peer document>#/components/…` or
      `#/functions/…`, where the document names the peer by `catalogId`
      or `$id`, exactly or by path suffix, before falling back to the
      file name (protocol guide, "Cross-Catalog References").

  `normalize/2` rewrites references into the common types and into the
  catalog itself as local `#/$defs/…` pointers; `inline/4` writes local
  and peer references inline, keeping references to common types.
  """

  @moduledoc since: "0.1.0"

  @common_types_document "common_types.json"
  @catalog_document "catalog.json"
  @envelope_keys ["id", "component", "catalogId"]

  @typedoc """
  A peer catalog for reference resolution: its ids and its document.
  """
  @type peer :: %{
          catalog_id: String.t() | nil,
          schema_id: String.t() | nil,
          document: map()
        }

  @doc """
  Whether the document part of a `$ref` is the file `name` or a path
  ending in it.
  """
  @spec names_document?(String.t(), String.t()) :: boolean()
  def names_document?(document, name),
    do: document == name or String.ends_with?(document, "/" <> name)

  @doc """
  Rewrites a cross-document `$defs` reference as a local pointer: one
  into the common types, into a document named `catalog.json`, or into a
  path ending in `/catalog.json` that names none of `peers`. Any other
  reference is returned unchanged.
  """
  @spec localize(String.t(), [peer()]) :: String.t()
  def localize(ref, peers \\ []) do
    if String.contains?(ref, "#/$defs/") and not String.starts_with?(ref, "#/") do
      [document, fragment] = String.split(ref, "#", parts: 2)
      if localizable?(document, peers), do: "#" <> fragment, else: ref
    else
      ref
    end
  end

  defp localizable?(document, peers) do
    names_document?(document, @common_types_document) or document == @catalog_document or
      (names_document?(document, @catalog_document) and match_by_id(document, peers) == nil)
  end

  @doc """
  Applies `localize/2` to every `$ref` in `node`.
  """
  @spec normalize(term(), [peer()]) :: term()
  def normalize(node, peers \\ [])

  def normalize(%{} = node, peers) do
    Map.new(node, fn
      {"$ref", ref} when is_binary(ref) -> {"$ref", localize(ref, peers)}
      {key, value} -> {key, normalize(value, peers)}
    end)
  end

  def normalize(list, peers) when is_list(list), do: Enum.map(list, &normalize(&1, peers))
  def normalize(other, _peers), do: other

  @doc """
  The peer a `$ref` document names, or `nil`. Common types and a document
  named exactly `catalog.json` never name a peer; a path ending in
  `/catalog.json` names one only by id. Otherwise ids are matched first
  (exactly or by path suffix), then file names; the first match in
  `peers` order wins.
  """
  @spec find_peer(String.t(), [peer()]) :: peer() | nil
  def find_peer(document, peers) do
    cond do
      document == "" or peers == [] -> nil
      names_document?(document, @common_types_document) -> nil
      document == @catalog_document -> nil
      true -> match_by_id(document, peers) || match_by_file(document, peers)
    end
  end

  defp match_by_file(document, peers) do
    if names_document?(document, @catalog_document) do
      nil
    else
      base = last_segment(document)

      Enum.find(peers, fn peer ->
        Enum.any?(
          [peer.schema_id, peer.catalog_id],
          &(is_binary(&1) and last_segment(&1) == base)
        )
      end)
    end
  end

  defp match_by_id(document, peers) do
    Enum.find(peers, fn peer ->
      Enum.any?([peer.catalog_id, peer.schema_id], &id_matches?(&1, document))
    end)
  end

  defp id_matches?(candidate, document) when is_binary(candidate) and candidate != "" do
    document == candidate or String.ends_with?(candidate, "/" <> document) or
      String.ends_with?(document, "/" <> candidate)
  end

  defp id_matches?(_candidate, _document), do: false

  defp last_segment(path), do: path |> String.split("/") |> List.last()

  @doc """
  Whether any `$ref` in `node` may point into a peer catalog: one with a
  document part other than the common types or `catalog.json`.
  """
  @spec cross_document?(term()) :: boolean()
  def cross_document?(%{} = node) do
    case node do
      %{"$ref" => ref} when is_binary(ref) ->
        cross_document_ref?(ref) or Enum.any?(Map.delete(node, "$ref"), &cross_value?/1)

      _other ->
        Enum.any?(node, &cross_value?/1)
    end
  end

  def cross_document?(list) when is_list(list), do: Enum.any?(list, &cross_document?/1)
  def cross_document?(_other), do: false

  defp cross_value?({_key, value}), do: cross_document?(value)

  defp cross_document_ref?(ref) do
    case String.split(ref, "#", parts: 2) do
      [document, _fragment] when document != "" ->
        not (names_document?(document, @common_types_document) or
               document == @catalog_document)

      _other ->
        false
    end
  end

  @doc """
  The names of the `$defs` that local `#/$defs/…` references in `node`
  target (the first segment after `#/$defs/`).
  """
  @spec def_refs(term()) :: MapSet.t(String.t())
  def def_refs(node), do: collect_def_refs(node, MapSet.new(), &local_def_target/1)

  @doc """
  Like `def_refs/1`, also counting references into a `catalog.json`
  document, which a catalog uses for its own definitions.
  """
  @spec own_def_refs(term()) :: MapSet.t(String.t())
  def own_def_refs(node), do: collect_def_refs(node, MapSet.new(), &own_def_name/1)

  defp collect_def_refs(%{} = node, acc, target) do
    acc =
      case target.(node["$ref"]) do
        nil -> acc
        name -> MapSet.put(acc, name)
      end

    Enum.reduce(node, acc, fn {_key, value}, acc -> collect_def_refs(value, acc, target) end)
  end

  defp collect_def_refs(list, acc, target) when is_list(list),
    do: Enum.reduce(list, acc, &collect_def_refs(&1, &2, target))

  defp collect_def_refs(_other, acc, _target), do: acc

  defp local_def_target("#/$defs/" <> rest), do: rest |> String.split("/") |> hd()
  defp local_def_target(_ref), do: nil

  @doc """
  The `$defs` name a reference into the same catalog targets: a local
  `#/$defs/X`, or a pointer into a `catalog.json` document.
  """
  @spec own_def_name(term()) :: String.t() | nil
  def own_def_name("#" <> _ = ref), do: local_def_target(ref)

  def own_def_name(ref) when is_binary(ref) do
    with [document, _fragment] <- String.split(ref, "#", parts: 2),
         true <- names_document?(document, @catalog_document) do
      ref |> localize() |> local_def_target()
    else
      _other -> nil
    end
  end

  def own_def_name(_ref), do: nil

  @doc """
  The names in `defs` that `roots` reference, transitively (counting
  references into `catalog.json`).
  """
  @spec reachable_defs([term()], map()) :: MapSet.t(String.t())
  def reachable_defs(roots, defs) do
    roots
    |> Enum.reduce(MapSet.new(), &MapSet.union(&2, own_def_refs(&1)))
    |> MapSet.to_list()
    |> walk_reachable(defs, %{})
    |> Map.keys()
    |> MapSet.new()
  end

  defp walk_reachable([], _defs, reached), do: reached

  defp walk_reachable([name | rest], defs, reached) do
    if Map.has_key?(defs, name) and not Map.has_key?(reached, name) do
      next = MapSet.to_list(own_def_refs(defs[name]))
      walk_reachable(next ++ rest, defs, Map.put(reached, name, true))
    else
      walk_reachable(rest, defs, reached)
    end
  end

  @doc """
  Points local references to the names in `common_names` at the common
  types document `document` (`#/$defs/X` becomes `<document>#/$defs/X`).
  """
  @spec externalize(term(), MapSet.t(String.t()), String.t()) :: term()
  def externalize(node, common_names, document \\ @common_types_document)

  def externalize(%{} = node, common_names, document) do
    Map.new(node, fn
      {"$ref", "#/$defs/" <> rest = ref} ->
        name = rest |> String.split("/") |> hd()

        if MapSet.member?(common_names, name),
          do: {"$ref", document <> ref},
          else: {"$ref", ref}

      {key, value} ->
        {key, externalize(value, common_names, document)}
    end)
  end

  def externalize(list, common_names, document) when is_list(list),
    do: Enum.map(list, &externalize(&1, common_names, document))

  def externalize(other, _common_names, _document), do: other

  @doc """
  The node a `#/…` JSON pointer addresses in `document`, or `nil`.
  """
  @spec query(term(), String.t()) :: term()
  def query(document, "#/" <> pointer) do
    pointer
    |> String.split("/")
    |> Enum.reduce_while(document, fn token, node ->
      token = token |> String.replace("~1", "/") |> String.replace("~0", "~")

      case node do
        %{^token => child} -> {:cont, child}
        _other -> {:halt, nil}
      end
    end)
  end

  def query(_document, _pointer), do: nil

  @doc """
  Writes the local and peer references of `node` inline.

  A `#/…` reference is replaced by its target in `root`, with the keys
  beside the `$ref` merged over it; a reference into a peer (see
  `find_peer/2`) by its target in the peer's document, whose own local
  references resolve against that document. A reference to a name in
  `preserved` (the common types) stays, and so does a reference that is
  already being expanded or whose target is missing. A whole component
  inherited through `#/components/<Name>` loses its envelope (`id`,
  `component`, `catalogId`) and closure keywords.
  """
  @spec inline(term(), map(), [peer()], MapSet.t(String.t())) :: term()
  def inline(node, root, peers, preserved),
    do: do_inline(node, {:root, root}, %{peers: peers, preserved: preserved, visited: []})

  defp do_inline(%{"$ref" => ref} = node, scope, ctx) when is_binary(ref) do
    case target(ref, scope, ctx) do
      {key, document, pointer} ->
        expand(node, key, document, pointer, scope, ctx)

      :keep ->
        node

      :none ->
        map_inline(node, scope, ctx)
    end
  end

  defp do_inline(%{} = node, scope, ctx), do: map_inline(node, scope, ctx)

  defp do_inline(list, scope, ctx) when is_list(list),
    do: Enum.map(list, &do_inline(&1, scope, ctx))

  defp do_inline(other, _scope, _ctx), do: other

  defp map_inline(node, scope, ctx),
    do: Map.new(node, fn {k, v} -> {k, do_inline(v, scope, ctx)} end)

  # Where a reference points: `{visit_key, document, pointer}`, `:keep`
  # for a preserved common type, or `:none` when it cannot be resolved.
  defp target("#/" <> _ = ref, scope, ctx), do: local_target(ref, scope, ctx)

  defp target(ref, scope, ctx) do
    case String.split(ref, "#", parts: 2) do
      [document, "/" <> _ = fragment] -> document_target(document, "#" <> fragment, scope, ctx)
      _other -> :none
    end
  end

  defp document_target(document, pointer, scope, ctx) do
    cond do
      names_document?(document, @common_types_document) ->
        if String.starts_with?(pointer, "#/$defs/"),
          do: local_target(pointer, scope, ctx),
          else: :none

      peer = find_peer(document, ctx.peers) ->
        {{scope_key({:peer, peer}), pointer}, {:peer, peer}, pointer}

      names_document?(document, @catalog_document) ->
        local_target(pointer, scope, ctx)

      true ->
        :none
    end
  end

  defp local_target(pointer, scope, ctx) do
    name = pointer |> String.split("/") |> List.last()

    if String.starts_with?(pointer, "#/$defs/") and MapSet.member?(ctx.preserved, name),
      do: :keep,
      else: {{scope_key(scope), pointer}, scope, pointer}
  end

  defp scope_key({:root, _root}), do: :root
  defp scope_key({:peer, peer}), do: {:peer, peer.catalog_id, peer.schema_id}

  defp expand(node, key, scope_ref, pointer, scope, ctx) do
    document = scope_document(scope_ref)

    with false <- key in ctx.visited,
         resolved when not is_nil(resolved) <- query(document, pointer) do
      resolved =
        resolved
        |> do_inline(scope_ref, %{ctx | visited: [key | ctx.visited]})
        |> strip_inherited_component(pointer)

      siblings = node |> Map.delete("$ref") |> map_inline(scope, ctx)
      merge_siblings(resolved, siblings)
    else
      _visited_or_missing -> if key in ctx.visited, do: node, else: map_inline(node, scope, ctx)
    end
  end

  defp scope_document({:root, root}), do: root
  defp scope_document({:peer, peer}), do: peer.document

  defp merge_siblings(%{} = resolved, siblings) do
    Enum.reduce(siblings, resolved, fn {key, value}, acc ->
      case {acc, value} do
        {%{^key => %{} = existing}, %{}} ->
          Map.put(acc, key, Map.merge(existing, value))

        {%{^key => existing}, list} when is_list(existing) and is_list(list) ->
          Map.put(acc, key, existing ++ Enum.reject(list, &(&1 in existing)))

        _other ->
          Map.put(acc, key, value)
      end
    end)
  end

  defp merge_siblings(resolved, _siblings), do: resolved

  defp strip_inherited_component(%{} = node, "#/components/" <> name) do
    if String.contains?(name, "/"), do: node, else: strip_envelope(node)
  end

  defp strip_inherited_component(node, _pointer), do: node

  @doc """
  Removes a component's envelope (`id`, `component` and `catalogId`
  properties and required names) and closure keywords, recursively
  through `allOf`, where the members that declare `component` move
  first.
  """
  @spec strip_envelope(map()) :: map()
  def strip_envelope(schema) do
    schema
    |> Map.drop(["unevaluatedProperties", "additionalProperties", "title"])
    |> update_present("properties", &if(is_map(&1), do: Map.drop(&1, @envelope_keys), else: &1))
    |> update_present("required", &if(is_list(&1), do: &1 -- @envelope_keys, else: &1))
    |> update_present("allOf", &strip_members/1)
  end

  defp strip_members(members) when is_list(members) do
    {specific, inherited} =
      Enum.split_with(members, fn
        %{"properties" => %{"component" => _}} -> true
        _other -> false
      end)

    Enum.map(specific ++ inherited, fn
      %{} = member -> strip_envelope(member)
      other -> other
    end)
  end

  defp strip_members(other), do: other

  defp update_present(map, key, fun) do
    case map do
      %{^key => value} -> Map.put(map, key, fun.(value))
      _other -> map
    end
  end
end

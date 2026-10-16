defmodule A2UICore.Catalog.SchemaCleaner do
  @moduledoc """
  Normalizes the schema nodes a catalog's validation schema is assembled
  from, as the reference catalog does before bundling common types:

    * a `title` keyword is dropped unless it was marked as authored
      (`mark_titles/1`);
    * `default: null` and `items: {}` are dropped;
    * `null` branches leave unions, and a union with one branch left
      becomes that branch;
    * an inline dynamic value union (a literal, a `DataBinding` and a
      `FunctionCall` branch) becomes a `$ref` to the common type it
      matches (`DynamicString`, `DynamicStringList`, `DynamicValue`, …);
    * `anyOf` becomes `oneOf`, except under `additionalProperties` and
      where a branch only constrains (`required` without `type`).

  `clean/2` also reports the `#/$defs/…` names the result references.
  """

  @moduledoc since: "0.1.0"

  @title_marker "x-a2ui-title"
  @data_keywords ["const", "default", "enum", "examples"]
  @annotation_keywords ["default", "description", "examples", "title", @title_marker]
  @scalar_kinds MapSet.new(["string", "number", "boolean"])
  @union_containers ["anyComponent", "anyFunction"]
  @plain %{properties: false, container: false, defs: false, additional: false}

  @typedoc """
  The dynamic value defs of a common types document, by the literal
  branches of their unions.
  """
  @type index :: %{
          names: MapSet.t(String.t()),
          by_scalar_kind: %{optional(String.t()) => String.t()},
          catch_all: String.t() | nil,
          by_literal_shape: %{optional(term()) => String.t()}
        }

  @doc """
  Builds the dynamic value index of a `$defs` map: every def whose union
  has a `DataBinding` branch, a `FunctionCall` branch and literal
  branches.
  """
  @spec index(map()) :: index()
  def index(defs) do
    dynamic =
      for {name, schema} <- Enum.sort(defs),
          items = union_items(schema),
          items != nil,
          kinds = literal_kinds(items),
          kinds != nil,
          do: {name, kinds, shape_key(items)}

    all_kinds =
      Enum.reduce(dynamic, MapSet.new(), fn {_n, kinds, _s}, acc -> MapSet.union(acc, kinds) end)

    catch_all =
      Enum.find_value(dynamic, fn {name, kinds, _shape} ->
        if MapSet.subset?(all_kinds, kinds), do: name
      end)

    %{
      names: MapSet.new(dynamic, &elem(&1, 0)),
      by_scalar_kind:
        for(
          {name, kinds, _shape} <- dynamic,
          MapSet.size(kinds) == 1 and MapSet.subset?(kinds, @scalar_kinds),
          into: %{},
          do: {hd(MapSet.to_list(kinds)), name}
        ),
      catch_all: catch_all,
      by_literal_shape:
        for(
          {name, kinds, shape} <- dynamic,
          name != catch_all and not MapSet.subset?(kinds, @scalar_kinds),
          into: %{},
          do: {shape, name}
        )
    }
  end

  @doc """
  Marks the `title` keywords of an authored schema so `clean/2` keeps
  them. A property named `title` and the values of data keywords
  (`const`, `default`, `enum`, `examples`) are left alone.
  """
  @spec mark_titles(term()) :: term()
  def mark_titles(node, in_properties \\ false)

  def mark_titles(%{} = node, in_properties) do
    Map.new(node, fn {key, value} ->
      cond do
        not in_properties and key in @data_keywords -> {key, value}
        not in_properties and key == "title" and is_binary(value) -> {@title_marker, value}
        true -> {key, mark_titles(value, not in_properties and key == "properties")}
      end
    end)
  end

  def mark_titles(list, _in_properties) when is_list(list), do: Enum.map(list, &mark_titles/1)
  def mark_titles(other, _in_properties), do: other

  @doc """
  Cleans `node` (see the module doc) with the dynamic value `index`,
  returning the cleaned node and the `#/$defs/…` names it references.
  """
  @spec clean(term(), index()) :: {term(), MapSet.t(String.t())}
  def clean(node, index) do
    {cleaned, acc} = do_clean(node, @plain, index, %{refs: MapSet.new()})
    {cleaned, acc.refs}
  end

  defp do_clean(%{} = node, ctx, index, acc) do
    {cleaned, acc} =
      Enum.reduce(node, {%{}, acc}, fn {key, value}, {map, acc} ->
        clean_entry(key, value, ctx, index, map, acc)
      end)

    node_keywords(cleaned, ctx, index, acc)
  end

  defp do_clean(list, _ctx, index, acc) when is_list(list) do
    {items, acc} =
      Enum.map_reduce(list, acc, fn item, acc -> do_clean(item, @plain, index, acc) end)

    {items, acc}
  end

  defp do_clean(other, _ctx, _index, acc), do: {other, acc}

  defp clean_entry("title", _value, %{properties: false}, _index, map, acc), do: {map, acc}

  defp clean_entry(@title_marker, value, %{properties: false}, _index, map, acc),
    do: {Map.put(map, "title", value), acc}

  defp clean_entry(key, value, %{properties: false}, _index, map, acc) when key in @data_keywords,
    do: {Map.put(map, key, value), acc}

  defp clean_entry(key, value, ctx, index, map, acc) do
    child = %{
      properties: key == "properties",
      container: key in @union_containers or (ctx.defs and MapSet.member?(index.names, key)),
      defs: key == "$defs" and not ctx.properties,
      additional: key == "additionalProperties" and not ctx.properties
    }

    {cleaned, acc} = do_clean(value, child, index, acc)
    {Map.put(map, key, cleaned), acc}
  end

  defp node_keywords(cleaned, ctx, index, acc) do
    acc = note_ref(cleaned, acc)

    cleaned =
      cleaned
      |> drop_null_default()
      |> drop_empty_items(ctx)

    case union_key(cleaned) do
      nil -> {cleaned, acc}
      key -> clean_union(cleaned, key, ctx, index, acc)
    end
  end

  defp note_ref(%{"$ref" => "#/$defs/" <> _ = ref}, acc),
    do: %{acc | refs: MapSet.put(acc.refs, ref |> String.split("/") |> List.last())}

  defp note_ref(_node, acc), do: acc

  defp drop_null_default(%{"default" => nil} = node), do: Map.delete(node, "default")
  defp drop_null_default(node), do: node

  defp drop_empty_items(%{"items" => items} = node, %{properties: false}) when items == %{},
    do: Map.delete(node, "items")

  defp drop_empty_items(node, _ctx), do: node

  defp union_key(%{"anyOf" => items}) when is_list(items), do: "anyOf"
  defp union_key(%{"anyOf" => _}), do: nil
  defp union_key(%{"oneOf" => items}) when is_list(items), do: "oneOf"
  defp union_key(_node), do: nil

  defp clean_union(cleaned, key, ctx, index, acc) do
    items = Enum.reject(cleaned[key], &type?(&1, "null"))
    parent = Map.delete(cleaned, key)

    case items do
      [single] when not ctx.container -> collapse_single(single, parent, ctx, index, acc)
      _many -> clean_many(cleaned, key, items, parent, ctx, index, acc)
    end
  end

  defp collapse_single(%{} = single, parent, ctx, index, acc) do
    merged = Map.merge(parent, single)
    node_keywords(merged, %{ctx | properties: false, container: false}, index, acc)
  end

  defp collapse_single(single, _parent, _ctx, _index, acc), do: {single, acc}

  defp clean_many(cleaned, key, items, parent, ctx, index, acc) do
    case if(ctx.container, do: nil, else: resolve_dynamic(items, index)) do
      nil ->
        keep_or_rewrite(cleaned, key, items, ctx, acc)

      target ->
        acc = %{acc | refs: MapSet.put(acc.refs, target)}
        {Map.merge(%{"$ref" => "#/$defs/" <> target}, parent), acc}
    end
  end

  defp keep_or_rewrite(cleaned, "anyOf", items, ctx, acc) do
    if ctx.additional or Enum.any?(items, &constraint_only?/1) do
      {cleaned, acc}
    else
      {cleaned |> Map.delete("anyOf") |> Map.put("oneOf", items), acc}
    end
  end

  defp keep_or_rewrite(cleaned, key, items, _ctx, acc), do: {Map.put(cleaned, key, items), acc}

  defp constraint_only?(%{"required" => _} = item),
    do: not Map.has_key?(item, "type") and not Map.has_key?(item, "$ref")

  defp constraint_only?(_item), do: false

  # -- dynamic value unions -------------------------------------------------------

  defp resolve_dynamic(items, index) do
    kinds = literal_kinds(items)

    cond do
      kinds == nil or MapSet.size(kinds) == 0 ->
        nil

      shape = Map.get(index.by_literal_shape, shape_key(items)) ->
        shape

      constrained_scalar?(items) ->
        nil

      MapSet.size(kinds) == 1 ->
        Map.get(index.by_scalar_kind, hd(MapSet.to_list(kinds))) || index.catch_all

      true ->
        index.catch_all
    end
  end

  defp constrained_scalar?(items) do
    items
    |> literal_branches()
    |> Enum.any?(fn item ->
      MapSet.member?(@scalar_kinds, literal_kind(item)) and
        Map.keys(strip_annotations(item)) -- ["type"] != []
    end)
  end

  defp literal_kinds(items) do
    if Enum.any?(items, &ref?(&1, "DataBinding")) and Enum.any?(items, &function_call_branch?/1) do
      items |> literal_branches() |> MapSet.new(&literal_kind/1)
    end
  end

  defp literal_branches(items) do
    Enum.reject(items, fn item ->
      ref?(item, "DataBinding") or function_call_branch?(item) or type?(item, "null")
    end)
  end

  defp literal_kind(%{"type" => "integer"}), do: "number"
  defp literal_kind(%{"type" => type}) when is_binary(type), do: type
  defp literal_kind(%{"additionalProperties" => _}), do: "object"
  defp literal_kind(%{"properties" => _}), do: "object"
  defp literal_kind(_item), do: "unknown"

  defp function_call_branch?(item) do
    ref?(item, "FunctionCall") or
      (match?(%{"allOf" => [_ | _]}, item) and Enum.any?(item["allOf"], &ref?(&1, "FunctionCall")))
  end

  defp ref?(%{"$ref" => ref}, target), do: ref == "#/$defs/" <> target
  defp ref?(_item, _target), do: false

  defp type?(%{"type" => type}, type), do: true
  defp type?(_item, _type), do: false

  defp shape_key(items),
    do: items |> literal_branches() |> Enum.map(&strip_annotations/1) |> Enum.sort()

  defp strip_annotations(node, in_properties \\ false)

  defp strip_annotations(%{} = node, in_properties) do
    for {key, value} <- node, in_properties or key not in @annotation_keywords, into: %{} do
      {key, strip_annotations(value, key == "properties" and not in_properties)}
    end
  end

  defp strip_annotations(list, _in_properties) when is_list(list),
    do: Enum.map(list, &strip_annotations/1)

  defp strip_annotations(other, _in_properties), do: other

  defp union_items(%{} = schema) do
    case schema["oneOf"] || schema["anyOf"] do
      items when is_list(items) -> items
      _other -> nil
    end
  end

  defp union_items(_schema), do: nil
end

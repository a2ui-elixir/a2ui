defmodule A2UICore.Catalog.RefSpec do
  @moduledoc """
  Which properties of a component refer to other components, and how to
  pull those references out of a component's properties.

  A spec has three parts, mirroring the reference `ComponentRefSpec`:

    * `single` — properties holding one child (`child`, `contentChild`),
    * `list` — properties holding many children (`children`, `tabs`),
    * `nested` — for list properties whose items are objects, the keys
      inside each item that hold the child (`tabs` → `child`).

  `extract/2` returns `{component_id, property_path}` pairs. Property
  paths are the reference's: `"child"`, `"children[0]"`,
  `"children.componentId"` (a template), `"tabs[1].child"`.

  Specs are derived from catalog schemas by
  `A2UICore.Catalog.ReferenceMap`; a surface keeps one per component
  type.

  Objects are traversed in sorted key order, so when a value holds
  several references the order is deterministic (the reference follows
  JSON insertion order).

      iex> spec = A2UICore.Catalog.RefSpec.new(single: ["child"], list: ["children"])
      iex> A2UICore.Catalog.RefSpec.extract(spec, %{"child" => "a", "children" => ["b", "c"]})
      [{"a", "child"}, {"b", "children[0]"}, {"c", "children[1]"}]
  """

  @moduledoc since: "0.1.0"

  @component_id_key "componentId"
  @child_key "child"

  defstruct single: MapSet.new(), list: MapSet.new(), nested: %{}

  @type t :: %__MODULE__{
          single: MapSet.t(String.t()),
          list: MapSet.t(String.t()),
          nested: %{optional(String.t()) => MapSet.t(String.t())}
        }

  @typedoc "A child reference: the referenced component id and the property path it came from."
  @type child_ref :: {component_id :: String.t(), property_path :: String.t()}

  @doc """
  Builds a spec. Options: `:single` and `:list` (lists of property
  names) and `:nested` (`%{list_property => [item_key]}`).
  """
  @spec new(keyword()) :: t()
  def new(options \\ []) do
    %__MODULE__{
      single: options |> Keyword.get(:single, []) |> MapSet.new(),
      list: options |> Keyword.get(:list, []) |> MapSet.new(),
      nested: options |> Keyword.get(:nested, %{}) |> Map.new(fn {k, v} -> {k, MapSet.new(v)} end)
    }
  end

  @doc "True when the spec names no child properties at all."
  @spec empty?(t()) :: boolean()
  def empty?(%__MODULE__{single: single, list: list}),
    do: MapSet.size(single) == 0 and MapSet.size(list) == 0

  @doc "True when `key` is a configured child property."
  @spec child_prop?(t(), String.t()) :: boolean()
  def child_prop?(%__MODULE__{single: single, list: list}, key),
    do: MapSet.member?(single, key) or MapSet.member?(list, key)

  @doc """
  Extracts `{component_id, property_path}` pairs from a component's
  `props` according to the spec: single properties first, then list
  properties.
  """
  @spec extract(t(), map()) :: [child_ref()]
  def extract(%__MODULE__{} = spec, props) when is_map(props) do
    singles =
      for key <- sorted(spec.single),
          Map.has_key?(props, key),
          {id, sub} <- from_value(Map.fetch!(props, key)),
          do: {id, join(key, sub)}

    lists =
      for key <- sorted(spec.list),
          Map.has_key?(props, key),
          reference <- list_references(key, Map.fetch!(props, key), spec.nested[key]),
          do: reference

    singles ++ lists
  end

  def extract(%__MODULE__{}, _props), do: []

  @doc """
  Extracts `{component_id, relative_path}` pairs from one property value
  (a component id, a `{child: id}` / `{componentId: id, path: …}` object,
  a list of those, or an object with nested child slots).

      iex> A2UICore.Catalog.RefSpec.from_value(%{"componentId" => "item", "path" => "/rows"})
      [{"item", "componentId"}]
      iex> A2UICore.Catalog.RefSpec.from_value([%{"child" => "x"}, "y"])
      [{"x", "[0].child"}, {"y", "[1]"}]
  """
  @spec from_value(term()) :: [{String.t(), String.t()}]
  def from_value(value) when is_binary(value) and value != "", do: [{value, ""}]

  def from_value(value) when is_list(value) do
    value
    |> Enum.with_index()
    |> Enum.flat_map(fn {item, index} ->
      for {id, sub} <- from_value(item), do: {id, "[#{index}]" <> dotted(sub)}
    end)
  end

  def from_value(value) when is_map(value) and map_size(value) > 0 do
    cond do
      non_empty_string?(value[@component_id_key]) ->
        [{value[@component_id_key], @component_id_key}]

      non_empty_string?(value[@child_key]) ->
        [{value[@child_key], @child_key}]

      true ->
        for key <- value |> Map.keys() |> Enum.sort(),
            {id, sub} <- from_value(Map.fetch!(value, key)),
            do: {id, key <> dotted(sub)}
    end
  end

  def from_value(_other), do: []

  # -- list properties ---------------------------------------------------------

  defp list_references(key, items, nested) when is_list(items) do
    items
    |> Enum.with_index()
    |> Enum.flat_map(fn {item, index} -> item_references(key, index, item, nested) end)
  end

  defp list_references(key, value, _nested) when is_binary(value) and value != "",
    do: [{value, key}]

  defp list_references(key, value, _nested) when is_map(value) do
    if non_empty_string?(value[@component_id_key]) do
      [{value[@component_id_key], "#{key}.#{@component_id_key}"}]
    else
      for {id, sub} <- from_value(value), do: {id, join(key, sub)}
    end
  end

  defp list_references(_key, _value, _nested), do: []

  defp item_references(key, index, item, _nested) when is_binary(item) and item != "",
    do: [{item, "#{key}[#{index}]"}]

  defp item_references(key, index, item, nested) when is_map(item) do
    cond do
      non_empty_string?(item[@component_id_key]) ->
        [{item[@component_id_key], "#{key}[#{index}].#{@component_id_key}"}]

      nested != nil and MapSet.size(nested) > 0 ->
        for sub_key <- sorted(nested),
            Map.has_key?(item, sub_key),
            {id, sub} <- from_value(Map.fetch!(item, sub_key)),
            do: {id, join("#{key}[#{index}].#{sub_key}", sub)}

      true ->
        for {id, sub} <- from_value(item), do: {id, join("#{key}[#{index}]", sub)}
    end
  end

  defp item_references(_key, _index, _item, _nested), do: []

  # Subscripts attach directly (`items[0]`); named keys are dot-separated.
  defp join(key, sub), do: key <> dotted(sub)

  defp dotted(""), do: ""
  defp dotted("[" <> _ = sub), do: sub
  defp dotted(sub), do: "." <> sub

  defp non_empty_string?(value), do: is_binary(value) and value != ""

  defp sorted(set), do: set |> MapSet.to_list() |> Enum.sort()
end

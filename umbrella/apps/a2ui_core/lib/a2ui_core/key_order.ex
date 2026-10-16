defmodule A2UICore.KeyOrder do
  @moduledoc """
  JSON values whose objects keep their key order, as
  `Jason.OrderedObject`s, for writing a document in a given order:
  `Jason.encode!/1` writes an ordered object's keys in order, and a
  map's in the map's own order.

      iex> template = Jason.decode!(~s({"b": 1, "a": 2}), objects: :ordered_objects)
      iex> %{"a" => 1, "b" => 2, "c" => 3} |> A2UICore.KeyOrder.like(template) |> Jason.encode!()
      ~s({"b":2,"a":1,"c":3})

  The functions that change an ordered object follow a JSON object built
  up in insertion order: `put/3` replaces a key's value where it stands
  and adds a new key last.
  """

  alias Jason.OrderedObject

  @moduledoc since: "0.1.0"

  @doc """
  An ordered object holding `pairs`, in their order.
  """
  @spec new([{String.t(), term()}]) :: OrderedObject.t()
  def new(pairs \\ []) when is_list(pairs), do: %OrderedObject{values: pairs}

  @doc """
  `value` with each map ordered like the object at the same place in
  `template` (an ordered object, or `nil` for none): first the keys the
  template has, in its order, then the others, sorted. Lists follow a
  template list item by item when both have the same length; otherwise
  each item follows a template item equal to it. Ordered objects in
  `value` keep their order.
  """
  @spec like(term(), term()) :: term()
  def like(%OrderedObject{} = value, _template), do: value

  def like(%{} = map, template) do
    template_keys = keys(template)
    listed = Enum.filter(template_keys, &Map.has_key?(map, &1))
    others = map |> Map.keys() |> Enum.reject(&(&1 in template_keys)) |> Enum.sort()

    new(Enum.map(listed ++ others, &{&1, like(Map.fetch!(map, &1), get(template, &1))}))
  end

  def like(list, template) when is_list(list),
    do: Enum.zip_with(list, item_templates(list, template), &like/2)

  def like(value, _template), do: value

  defp keys(%OrderedObject{values: values}), do: Enum.map(values, &elem(&1, 0))
  defp keys(_template), do: []

  defp item_templates(list, template) when is_list(template) do
    if length(template) == length(list) do
      template
    else
      Enum.map(list, fn item -> Enum.find(template, &(to_plain(&1) == item)) end)
    end
  end

  defp item_templates(list, _template), do: List.duplicate(nil, length(list))

  @doc """
  The value of `key` in an ordered object or map, or `nil`.
  """
  @spec get(term(), String.t()) :: term()
  def get(%OrderedObject{values: values}, key) do
    case List.keyfind(values, key, 0) do
      {^key, value} -> value
      nil -> nil
    end
  end

  def get(%{} = map, key), do: Map.get(map, key)
  def get(_other, _key), do: nil

  @doc """
  Whether an ordered object or map has `key`.
  """
  @spec has_key?(term(), String.t()) :: boolean()
  def has_key?(%OrderedObject{values: values}, key), do: List.keymember?(values, key, 0)
  def has_key?(%{} = map, key), do: Map.has_key?(map, key)
  def has_key?(_other, _key), do: false

  @doc """
  Sets `key` to `value`: in place when the object has the key, else as
  its last key.
  """
  @spec put(OrderedObject.t(), String.t(), term()) :: OrderedObject.t()
  def put(%OrderedObject{values: values} = object, key, value) do
    if List.keymember?(values, key, 0),
      do: %{object | values: List.keyreplace(values, key, 0, {key, value})},
      else: %{object | values: values ++ [{key, value}]}
  end

  @doc """
  Sets `key` to `value` unless the object has the key.
  """
  @spec put_new(OrderedObject.t(), String.t(), term()) :: OrderedObject.t()
  def put_new(%OrderedObject{} = object, key, value) do
    if has_key?(object, key), do: object, else: put(object, key, value)
  end

  @doc """
  Removes `key`.
  """
  @spec delete(OrderedObject.t(), String.t()) :: OrderedObject.t()
  def delete(%OrderedObject{values: values} = object, key),
    do: %{object | values: List.keydelete(values, key, 0)}

  @doc """
  Whether an ordered object or map has no keys.
  """
  @spec empty?(OrderedObject.t() | map()) :: boolean()
  def empty?(%OrderedObject{values: values}), do: values == []
  def empty?(%{} = map), do: map_size(map) == 0

  @doc """
  `term` with its ordered objects turned into maps.
  """
  @spec to_plain(term()) :: term()
  def to_plain(%OrderedObject{values: values}),
    do: Map.new(values, fn {key, value} -> {key, to_plain(value)} end)

  def to_plain(%{} = map), do: Map.new(map, fn {key, value} -> {key, to_plain(value)} end)
  def to_plain(list) when is_list(list), do: Enum.map(list, &to_plain/1)
  def to_plain(other), do: other
end

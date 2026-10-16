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

  # The keys of each message body, in the order the protocol's schemas
  # list them (v0.9 and v1.0 agree where both define a key).
  @body_keys %{
    "createSurface" => ~w(surfaceId catalogId theme sendDataModel components dataModel metadata),
    "updateComponents" => ~w(surfaceId components),
    "updateDataModel" => ~w(surfaceId path value),
    "deleteSurface" => ~w(surfaceId),
    "callRendererFunction" => ~w(surfaceId functionCallId callFunction),
    "agentFunctionResponse" => ~w(functionCallId value error)
  }

  @doc """
  An agent-to-renderer message as an ordered object, its keys in the
  order the protocol's schemas list them, which is also the order a
  model is shown and writes them: `version` first, then the message;
  in its body `surfaceId` first and the components and data last; in a
  component `id` and `component` first. Other keys follow, sorted. Data
  values and ordered objects keep their order; anything but a map is
  returned as it is.

  A streaming reader can only act on a message once its `surfaceId` has
  arrived, so this order lets a surface build while its message streams.

      iex> %{"updateComponents" => %{"components" => [], "surfaceId" => "s"}, "version" => "v1.0"}
      ...> |> A2UICore.KeyOrder.message()
      ...> |> Jason.encode!()
      ~s({"version":"v1.0","updateComponents":{"surfaceId":"s","components":[]}})
  """
  @spec message(term()) :: term()
  def message(%OrderedObject{} = message), do: message

  def message(%{} = message) do
    {version, rest} = Map.split(message, ["version"])

    new(
      Enum.to_list(version) ++
        Enum.map(Enum.sort(rest), fn {key, body} -> {key, body(key, body)} end)
    )
  end

  def message(other), do: other

  defp body(kind, %{} = body) when not is_struct(body) do
    listed = Enum.filter(Map.get(@body_keys, kind, []), &Map.has_key?(body, &1))
    others = body |> Map.keys() |> Enum.reject(&(&1 in listed)) |> Enum.sort()

    new(Enum.map(listed ++ others, fn key -> {key, body_value(key, Map.fetch!(body, key))} end))
  end

  defp body(_kind, body), do: body

  defp body_value("components", components) when is_list(components),
    do: Enum.map(components, &component/1)

  defp body_value(_key, value), do: value

  defp component(%{} = component) when not is_struct(component) do
    listed = Enum.filter(["id", "component"], &Map.has_key?(component, &1))
    others = component |> Map.drop(listed) |> Enum.sort()
    new(Enum.map(listed, &{&1, Map.fetch!(component, &1)}) ++ others)
  end

  defp component(component), do: component

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
  its last key. A map is updated with `Map.put/3`.
  """
  @spec put(OrderedObject.t(), String.t(), term()) :: OrderedObject.t()
  @spec put(map(), String.t(), term()) :: map()
  def put(%OrderedObject{values: values} = object, key, value) do
    if List.keymember?(values, key, 0),
      do: %{object | values: List.keyreplace(values, key, 0, {key, value})},
      else: %{object | values: values ++ [{key, value}]}
  end

  def put(%{} = map, key, value), do: Map.put(map, key, value)

  @doc """
  Sets `key` to `value` unless the object has the key.
  """
  @spec put_new(OrderedObject.t(), String.t(), term()) :: OrderedObject.t()
  def put_new(%OrderedObject{} = object, key, value) do
    if has_key?(object, key), do: object, else: put(object, key, value)
  end

  @doc """
  Removes `key` from an ordered object or map.
  """
  @spec delete(OrderedObject.t(), String.t()) :: OrderedObject.t()
  @spec delete(map(), String.t()) :: map()
  def delete(%OrderedObject{values: values} = object, key),
    do: %{object | values: List.keydelete(values, key, 0)}

  def delete(%{} = map, key), do: Map.delete(map, key)

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

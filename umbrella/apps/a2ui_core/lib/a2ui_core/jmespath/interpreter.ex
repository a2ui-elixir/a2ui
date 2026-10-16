defmodule A2UICore.JMESPath.Interpreter do
  @moduledoc false

  # Evaluates a parsed JMESPath expression (see A2UICore.JMESPath.Parser)
  # against JSON data. Errors are thrown as `{:jmespath, code, message}`.

  alias A2UICore.JMESPath.Functions

  @spec visit(term(), term()) :: term()
  def visit({:field, name}, %{} = value), do: Map.get(value, name)
  def visit({:field, _name}, _value), do: nil

  def visit({:subexpression, children}, value), do: Enum.reduce(children, value, &visit/2)
  def visit({:index_expression, children}, value), do: Enum.reduce(children, value, &visit/2)

  def visit({:index, index}, list) when is_list(list) do
    if index < 0 and -index > length(list), do: nil, else: Enum.at(list, index)
  end

  def visit({:index, _index}, _value), do: nil

  def visit({:slice, start, stop, step}, list) when is_list(list),
    do: slice(list, start, stop, step || 1)

  def visit({:slice, _, _, _}, _value), do: nil

  def visit({:projection, left, right}, value) do
    case visit(left, value) do
      list when is_list(list) -> project(list, right)
      _other -> nil
    end
  end

  def visit({:value_projection, left, right}, value) do
    case visit(left, value) do
      %{} = map -> map |> Map.values() |> project(right)
      _other -> nil
    end
  end

  def visit({:filter_projection, left, right, condition}, value) do
    case visit(left, value) do
      list when is_list(list) ->
        list |> Enum.filter(&truthy?(visit(condition, &1))) |> project(right)

      _other ->
        nil
    end
  end

  def visit({:flatten, inner}, value) do
    case visit(inner, value) do
      list when is_list(list) -> Enum.flat_map(list, &flatten_item/1)
      _other -> nil
    end
  end

  def visit(:identity, value), do: value
  def visit(:current, value), do: value
  def visit({:literal, literal}, _value), do: literal

  def visit({:multi_select_list, _children}, nil), do: nil
  def visit({:multi_select_list, children}, value), do: Enum.map(children, &visit(&1, value))

  def visit({:multi_select_hash, _pairs}, nil), do: nil

  def visit({:multi_select_hash, pairs}, value),
    do: Map.new(pairs, fn {key, node} -> {key, visit(node, value)} end)

  def visit({:or, left, right}, value) do
    matched = visit(left, value)
    if truthy?(matched), do: matched, else: visit(right, value)
  end

  def visit({:and, left, right}, value) do
    matched = visit(left, value)
    if truthy?(matched), do: visit(right, value), else: matched
  end

  def visit({:not, inner}, value), do: not truthy?(visit(inner, value))

  def visit({:pipe, left, right}, value), do: visit(right, visit(left, value))

  def visit({:comparator, op, left, right}, value),
    do: compare(op, visit(left, value), visit(right, value))

  def visit({:function, name, args}, value),
    do: Functions.call(name, Enum.map(args, &visit(&1, value)))

  def visit({:expref, node}, _value), do: {:expref, node}

  @doc "JMESPath truthiness: false, null, and empty strings, arrays and objects are false."
  @spec truthy?(term()) :: boolean()
  def truthy?(value), do: value not in [false, nil, "", [], %{}]

  defp project(list, right) do
    Enum.flat_map(list, fn item ->
      case visit(right, item) do
        nil -> []
        result -> [result]
      end
    end)
  end

  defp flatten_item(item) when is_list(item), do: item
  defp flatten_item(item), do: [item]

  defp compare(:eq, left, right), do: equal?(left, right)
  defp compare(:ne, left, right), do: not equal?(left, right)

  defp compare(op, left, right) when is_number(left) and is_number(right) do
    case op do
      :lt -> left < right
      :lte -> left <= right
      :gt -> left > right
      :gte -> left >= right
    end
  end

  defp compare(_op, _left, _right), do: nil

  # JSON equality: numbers by value, booleans never equal to numbers.
  @spec equal?(term(), term()) :: boolean()
  def equal?(left, right) when is_boolean(left) or is_boolean(right), do: left === right
  def equal?(left, right) when is_number(left) and is_number(right), do: left == right

  def equal?(left, right) when is_list(left) and is_list(right) do
    length(left) == length(right) and
      left |> Enum.zip(right) |> Enum.all?(fn {a, b} -> equal?(a, b) end)
  end

  def equal?(%{} = left, %{} = right) do
    map_size(left) == map_size(right) and
      Enum.all?(left, fn {key, a} -> Map.has_key?(right, key) and equal?(a, right[key]) end)
  end

  def equal?(left, right), do: left === right

  # Python slice semantics.
  defp slice(list, start, stop, step) do
    length = length(list)
    start = bound(start, length, step, if(step < 0, do: length - 1, else: 0))
    stop = bound(stop, length, step, if(step < 0, do: -1, else: length))
    indices = slice_indices(start, stop, step)
    tuple = List.to_tuple(list)
    Enum.map(indices, &elem(tuple, &1))
  end

  defp bound(nil, _length, _step, default), do: default

  defp bound(index, length, step, _default) when index < 0 do
    adjusted = index + length
    if adjusted < 0, do: if(step < 0, do: -1, else: 0), else: adjusted
  end

  defp bound(index, length, step, _default) when index >= length,
    do: if(step < 0, do: length - 1, else: length)

  defp bound(index, _length, _step, _default), do: index

  defp slice_indices(start, stop, step) when step > 0 and start < stop,
    do: Enum.take_every(start..(stop - 1)//1, step)

  defp slice_indices(start, stop, step) when step < 0 and start > stop,
    do: Enum.take_every(start..(stop + 1)//-1, -step)

  defp slice_indices(_start, _stop, _step), do: []
end

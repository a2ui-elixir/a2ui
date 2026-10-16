defmodule A2UICore.JMESPath.Functions do
  @moduledoc false

  # The JMESPath built-in functions, with the specification's argument
  # types. Errors are thrown as `{:jmespath, code, message}`.

  alias A2UICore.JMESPath.Interpreter

  # Each argument lists the types it accepts; `{:variadic, types}` takes
  # one or more arguments of those types.
  @signatures %{
    "abs" => [[:number]],
    "avg" => [[:array_number]],
    "ceil" => [[:number]],
    "contains" => [[:array, :string], [:any]],
    "ends_with" => [[:string], [:string]],
    "floor" => [[:number]],
    "join" => [[:string], [:array_string]],
    "keys" => [[:object]],
    "length" => [[:string, :array, :object]],
    "map" => [[:expref], [:array]],
    "max" => [[:array_number, :array_string]],
    "max_by" => [[:array], [:expref]],
    "merge" => {:variadic, [:object]},
    "min" => [[:array_number, :array_string]],
    "min_by" => [[:array], [:expref]],
    "not_null" => {:variadic, [:any]},
    "reverse" => [[:string, :array]],
    "sort" => [[:array_number, :array_string]],
    "sort_by" => [[:array], [:expref]],
    "starts_with" => [[:string], [:string]],
    "sum" => [[:array_number]],
    "to_array" => [[:any]],
    "to_number" => [[:any]],
    "to_string" => [[:any]],
    "type" => [[:any]],
    "values" => [[:object]]
  }

  @spec call(String.t(), [term()]) :: term()
  def call(name, args) do
    case Map.fetch(@signatures, name) do
      {:ok, signature} ->
        check_arity!(name, signature, args)
        check_types!(name, signature, args)
        run(name, args)

      :error ->
        throw({:jmespath, "unknown-function", "Unknown function: #{name}()"})
    end
  end

  # -- checks -----------------------------------------------------------------

  defp check_arity!(name, {:variadic, _types}, []),
    do: arity!(name, "at least 1 argument", 0)

  defp check_arity!(_name, {:variadic, _types}, _args), do: :ok

  defp check_arity!(name, signature, args) when length(signature) != length(args),
    do: arity!(name, "#{length(signature)} argument(s)", length(args))

  defp check_arity!(_name, _signature, _args), do: :ok

  @spec arity!(String.t(), String.t(), non_neg_integer()) :: no_return()
  defp arity!(name, expected, received) do
    throw(
      {:jmespath, "invalid-arity", "Function #{name}() expects #{expected}, received #{received}"}
    )
  end

  defp check_types!(name, {:variadic, types}, args),
    do: Enum.each(args, &check_type!(name, types, &1))

  defp check_types!(name, signature, args),
    do:
      signature
      |> Enum.zip(args)
      |> Enum.each(fn {types, arg} -> check_type!(name, types, arg) end)

  defp check_type!(name, types, arg) do
    unless Enum.any?(types, &type?(&1, arg)) do
      type_error!(name, arg, Enum.map(types, &type_label/1))
    end
  end

  defp type?(:any, _arg), do: true
  defp type?(:number, arg), do: is_number(arg)
  defp type?(:string, arg), do: is_binary(arg)
  defp type?(:array, arg), do: is_list(arg)
  defp type?(:object, arg), do: is_map(arg)
  defp type?(:expref, arg), do: match?({:expref, _}, arg)
  defp type?(:array_number, arg), do: is_list(arg) and Enum.all?(arg, &is_number/1)
  defp type?(:array_string, arg), do: is_list(arg) and Enum.all?(arg, &is_binary/1)

  defp type_label(:array_number), do: "array[number]"
  defp type_label(:array_string), do: "array[string]"
  defp type_label(type), do: Atom.to_string(type)

  @spec type_error!(String.t(), term(), [String.t()]) :: no_return()
  defp type_error!(name, value, expected) do
    throw(
      {:jmespath, "invalid-type",
       "In function #{name}(), invalid type for value: #{describe(value)}, expected one of: " <>
         "#{Enum.join(expected, ", ")}, received: #{type_name(value)}"}
    )
  end

  defp describe({:expref, _node}), do: "an expression"
  defp describe(value), do: Jason.encode!(value)

  # -- functions --------------------------------------------------------------

  defp run("abs", [n]), do: abs(n)
  defp run("avg", [[]]), do: nil
  defp run("avg", [list]), do: Enum.sum(list) / length(list)
  defp run("ceil", [n]), do: ceil(n)

  defp run("contains", [subject, search]) when is_binary(subject),
    do: is_binary(search) and String.contains?(subject, search)

  defp run("contains", [list, search]), do: Enum.any?(list, &Interpreter.equal?(&1, search))
  defp run("ends_with", [string, suffix]), do: String.ends_with?(string, suffix)
  defp run("floor", [n]), do: floor(n)
  defp run("join", [glue, list]), do: Enum.join(list, glue)
  defp run("keys", [map]), do: Map.keys(map)

  defp run("length", [string]) when is_binary(string),
    do: string |> String.codepoints() |> length()

  defp run("length", [list]) when is_list(list), do: length(list)
  defp run("length", [map]), do: map_size(map)
  defp run("map", [{:expref, node}, list]), do: Enum.map(list, &Interpreter.visit(node, &1))
  defp run("max", [[]]), do: nil
  defp run("max", [list]), do: Enum.max(list)
  defp run("max_by", [list, {:expref, node}]), do: by(list, node, "max_by", &Enum.max_by/2)
  defp run("merge", maps), do: Enum.reduce(maps, %{}, &Map.merge(&2, &1))
  defp run("min", [[]]), do: nil
  defp run("min", [list]), do: Enum.min(list)
  defp run("min_by", [list, {:expref, node}]), do: by(list, node, "min_by", &Enum.min_by/2)
  defp run("not_null", args), do: Enum.find(args, &(&1 != nil))

  defp run("reverse", [string]) when is_binary(string),
    do: string |> String.codepoints() |> Enum.reverse() |> Enum.join()

  defp run("reverse", [list]), do: Enum.reverse(list)
  defp run("sort", [list]), do: Enum.sort(list)
  defp run("sort_by", [list, {:expref, node}]), do: by(list, node, "sort_by", &Enum.sort_by/2)
  defp run("starts_with", [string, prefix]), do: String.starts_with?(string, prefix)
  defp run("sum", [list]), do: Enum.sum(list)
  defp run("to_array", [list]) when is_list(list), do: list
  defp run("to_array", [value]), do: [value]
  defp run("to_number", [n]) when is_number(n), do: n
  defp run("to_number", [string]) when is_binary(string), do: to_number(string)
  defp run("to_number", [_value]), do: nil
  defp run("to_string", [string]) when is_binary(string), do: string
  defp run("to_string", [value]), do: Jason.encode!(value)
  defp run("type", [value]), do: type_name(value)
  defp run("values", [map]), do: Map.values(map)

  # `max_by`, `min_by` and `sort_by`: the keys must all be numbers or all
  # strings, decided by the first one.
  defp by([], _node, "sort_by", _pick), do: []
  defp by([], _node, _name, _pick), do: nil

  defp by(list, node, name, pick) do
    keyed = Enum.map(list, &{Interpreter.visit(node, &1), &1})
    {first, _item} = hd(keyed)

    kind =
      cond do
        is_number(first) -> :number
        is_binary(first) -> :string
        true -> type_error!(name, first, ["number", "string"])
      end

    Enum.each(keyed, fn {key, _item} ->
      unless type?(kind, key), do: type_error!(name, key, [Atom.to_string(kind)])
    end)

    case pick.(keyed, fn {key, _item} -> key end) do
      {_key, item} -> item
      sorted -> Enum.map(sorted, fn {_key, item} -> item end)
    end
  end

  defp to_number(string) do
    case Integer.parse(string) do
      {n, ""} ->
        n

      _not_an_integer ->
        case Float.parse(string) do
          {f, ""} -> f
          _not_a_number -> nil
        end
    end
  end

  defp type_name(value) when is_number(value), do: "number"
  defp type_name(value) when is_binary(value), do: "string"
  defp type_name(value) when is_boolean(value), do: "boolean"
  defp type_name(value) when is_list(value), do: "array"
  defp type_name(value) when is_map(value), do: "object"
  defp type_name(nil), do: "null"
  defp type_name({:expref, _node}), do: "expref"
end

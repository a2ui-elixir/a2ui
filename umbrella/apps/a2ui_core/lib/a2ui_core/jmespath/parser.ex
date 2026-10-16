defmodule A2UICore.JMESPath.Parser do
  @moduledoc false

  # A top-down operator-precedence (Pratt) parser for JMESPath, after the
  # reference implementation (jmespath.py). Nodes:
  #
  #   {:field, name}                {:literal, value}
  #   :identity                     :current
  #   {:subexpression, [node]}      {:index_expression, [node]}
  #   {:index, integer}             {:slice, start, stop, step}
  #   {:projection, left, right}    {:value_projection, left, right}
  #   {:filter_projection, left, right, condition}
  #   {:flatten, node}              {:not, node}
  #   {:or, left, right}            {:and, left, right}
  #   {:pipe, left, right}          {:comparator, op, left, right}
  #   {:multi_select_list, [node]}  {:multi_select_hash, [{key, node}]}
  #   {:function, name, [node]}     {:expref, node}
  #
  # Errors are thrown as `{:jmespath, code, message}`.

  alias A2UICore.JMESPath.Lexer

  @binding_power %{
    eof: 0,
    unquoted_identifier: 0,
    quoted_identifier: 0,
    literal: 0,
    rbracket: 0,
    rparen: 0,
    comma: 0,
    rbrace: 0,
    number: 0,
    current: 0,
    expref: 0,
    colon: 0,
    pipe: 1,
    or: 2,
    and: 3,
    eq: 5,
    gt: 5,
    lt: 5,
    gte: 5,
    lte: 5,
    ne: 5,
    flatten: 9,
    star: 20,
    filter: 21,
    dot: 40,
    not: 45,
    lbrace: 50,
    lbracket: 55,
    lparen: 60
  }

  # Tokens binding less tightly than this end a projection.
  @projection_stop 10

  @comparators [:eq, :ne, :lt, :lte, :gt, :gte]

  @type tokens :: [Lexer.token()]

  @spec parse(String.t()) :: term()
  def parse(expression) do
    case expression(Lexer.tokenize(expression), 0) do
      {ast, [{:eof, _, _}]} -> ast
      {_ast, [token | _]} -> unexpected!(token)
    end
  end

  defp expression([token | rest], power) do
    {left, rest} = nud(token, rest)
    led_loop(left, rest, power)
  end

  defp led_loop(left, [{type, _, _} = token | rest] = tokens, power) do
    if power < Map.fetch!(@binding_power, type) do
      {left, rest} = led(token, left, rest)
      led_loop(left, rest, power)
    else
      {left, tokens}
    end
  end

  # -- prefix positions -----------------------------------------------------

  defp nud({:literal, value, _}, rest), do: {{:literal, value}, rest}
  defp nud({:unquoted_identifier, name, _}, rest), do: {{:field, name}, rest}

  defp nud({:quoted_identifier, name, pos}, rest) do
    if match?([{:lparen, _, _} | _], rest),
      do: syntax!("Quoted identifier not allowed for function names (position #{pos})"),
      else: {{:field, name}, rest}
  end

  defp nud({:star, _, _}, [{:rbracket, _, _} | _] = rest),
    do: {{:value_projection, :identity, :identity}, rest}

  defp nud({:star, _, _}, rest) do
    {right, rest} = projection_rhs(rest, @binding_power.star)
    {{:value_projection, :identity, right}, rest}
  end

  defp nud({:filter, _, _} = token, rest), do: led(token, :identity, rest)
  defp nud({:lbrace, _, _}, rest), do: multi_select_hash(rest, [])

  defp nud({:lparen, _, _}, rest) do
    {inner, rest} = expression(rest, 0)
    {inner, match(rest, :rparen)}
  end

  defp nud({:flatten, _, _}, rest) do
    {right, rest} = projection_rhs(rest, @binding_power.flatten)
    {{:projection, {:flatten, :identity}, right}, rest}
  end

  defp nud({:not, _, _}, rest) do
    {inner, rest} = expression(rest, @binding_power.not)
    {{:not, inner}, rest}
  end

  defp nud({:lbracket, _, _}, [{type, _, _} | _] = rest) when type in [:number, :colon] do
    {right, rest} = index_expression(rest)
    project_if_slice(:identity, right, rest)
  end

  defp nud({:lbracket, _, _}, [{:star, _, _}, {:rbracket, _, _} | rest]) do
    {right, rest} = projection_rhs(rest, @binding_power.star)
    {{:projection, :identity, right}, rest}
  end

  defp nud({:lbracket, _, _}, rest), do: multi_select_list(rest, [])
  defp nud({:current, _, _}, rest), do: {:current, rest}

  defp nud({:expref, _, _}, rest) do
    {inner, rest} = expression(rest, @binding_power.expref)
    {{:expref, inner}, rest}
  end

  defp nud(token, _rest), do: unexpected!(token)

  # -- infix positions ------------------------------------------------------

  defp led({:dot, _, _}, left, [{:star, _, _} | rest]) do
    {right, rest} = projection_rhs(rest, @binding_power.dot)
    {{:value_projection, left, right}, rest}
  end

  defp led({:dot, _, _}, left, rest) do
    {right, rest} = dot_rhs(rest, @binding_power.dot)

    case left do
      {:subexpression, children} -> {{:subexpression, children ++ [right]}, rest}
      _other -> {{:subexpression, [left, right]}, rest}
    end
  end

  defp led({type, _, _}, left, rest) when type in [:pipe, :or, :and] do
    {right, rest} = expression(rest, Map.fetch!(@binding_power, type))
    {{type, left, right}, rest}
  end

  defp led({type, _, _}, left, rest) when type in @comparators do
    {right, rest} = expression(rest, Map.fetch!(@binding_power, type))
    {{:comparator, type, left, right}, rest}
  end

  defp led({:lparen, _, _}, {:field, name}, rest), do: arguments(rest, name, [])

  defp led({:lparen, _, pos}, _left, _rest),
    do: syntax!("Invalid function name at position #{pos}")

  defp led({:filter, _, _}, left, rest) do
    {condition, rest} = expression(rest, 0)
    rest = match(rest, :rbracket)

    {right, rest} =
      case rest do
        [{:flatten, _, _} | _] -> {:identity, rest}
        _other -> projection_rhs(rest, @binding_power.filter)
      end

    {{:filter_projection, left, right, condition}, rest}
  end

  defp led({:flatten, _, _}, left, rest) do
    {right, rest} = projection_rhs(rest, @binding_power.flatten)
    {{:projection, {:flatten, left}, right}, rest}
  end

  defp led({:lbracket, _, _}, left, [{type, _, _} | _] = rest) when type in [:number, :colon] do
    {right, rest} = index_expression(rest)

    case left do
      {:index_expression, children} -> {{:index_expression, children ++ [right]}, rest}
      _other -> project_if_slice(left, right, rest)
    end
  end

  defp led({:lbracket, _, _}, left, rest) do
    rest = rest |> match(:star) |> match(:rbracket)
    {right, rest} = projection_rhs(rest, @binding_power.star)
    {{:projection, left, right}, rest}
  end

  defp led(token, _left, _rest), do: unexpected!(token)

  # -- pieces ---------------------------------------------------------------

  defp arguments([{:rparen, _, _} | rest], name, args),
    do: {{:function, name, Enum.reverse(args)}, rest}

  defp arguments(tokens, name, args) do
    {arg, rest} = expression(tokens, 0)

    case rest do
      [{:comma, _, _} | rest] -> arguments(rest, name, [arg | args])
      [{:rparen, _, _} | _] -> arguments(rest, name, [arg | args])
      [token | _] -> unexpected!(token)
    end
  end

  defp project_if_slice(left, {:slice, _, _, _} = slice, rest) do
    {right, rest} = projection_rhs(rest, @binding_power.star)
    {{:projection, {:index_expression, [left, slice]}, right}, rest}
  end

  defp project_if_slice(left, index, rest), do: {{:index_expression, [left, index]}, rest}

  defp index_expression([{:colon, _, _} | _] = tokens), do: slice(tokens, [nil, nil, nil], 0)
  defp index_expression([_, {:colon, _, _} | _] = tokens), do: slice(tokens, [nil, nil, nil], 0)

  defp index_expression([{:number, n, _} | rest]), do: {{:index, n}, match(rest, :rbracket)}

  defp slice([{:rbracket, _, _} | rest], [start, stop, step], _at) do
    if step == 0, do: throw({:jmespath, "invalid-value", "Slice step cannot be 0"})
    {{:slice, start, stop, step}, rest}
  end

  defp slice([{:colon, _, _} = token | _], _parts, 2), do: unexpected!(token)
  defp slice([{:colon, _, _} | rest], parts, at), do: slice(rest, parts, at + 1)

  defp slice([{:number, n, _} | rest], parts, at),
    do: slice(rest, List.replace_at(parts, at, n), at)

  defp slice([token | _], _parts, _at), do: unexpected!(token)

  defp projection_rhs([{type, _, _} | _] = tokens, power) do
    cond do
      Map.fetch!(@binding_power, type) < @projection_stop -> {:identity, tokens}
      type in [:lbracket, :filter] -> expression(tokens, power)
      type == :dot -> tokens |> tl() |> dot_rhs(power)
      true -> unexpected!(hd(tokens))
    end
  end

  defp dot_rhs([{type, _, _} | _] = tokens, power)
       when type in [:quoted_identifier, :unquoted_identifier, :star],
       do: expression(tokens, power)

  defp dot_rhs([{:lbracket, _, _} | rest], _power), do: multi_select_list(rest, [])
  defp dot_rhs([{:lbrace, _, _} | rest], _power), do: multi_select_hash(rest, [])

  defp dot_rhs([{_, _, pos} | _], _power),
    do: syntax!("Expecting an identifier, '[' or '{' after '.' at position #{pos}")

  defp multi_select_list(tokens, acc) do
    {item, rest} = expression(tokens, 0)

    case rest do
      [{:rbracket, _, _} | rest] -> {{:multi_select_list, Enum.reverse([item | acc])}, rest}
      [{:comma, _, _} | rest] -> multi_select_list(rest, [item | acc])
      [token | _] -> unexpected!(token)
    end
  end

  defp multi_select_hash([{type, key, _} | rest], acc)
       when type in [:quoted_identifier, :unquoted_identifier] do
    {value, rest} = expression(match(rest, :colon), 0)
    pairs = [{key, value} | acc]

    case rest do
      [{:comma, _, _} | rest] -> multi_select_hash(rest, pairs)
      [{:rbrace, _, _} | rest] -> {{:multi_select_hash, Enum.reverse(pairs)}, rest}
      [token | _] -> unexpected!(token)
    end
  end

  defp multi_select_hash([token | _], _acc), do: unexpected!(token)

  defp match([{type, _, _} | rest], type), do: rest
  defp match([token | _], _type), do: unexpected!(token)

  @spec unexpected!(Lexer.token()) :: no_return()
  defp unexpected!({:eof, _, _}), do: syntax!("Unexpected end of expression")

  defp unexpected!({type, value, pos}),
    do: syntax!("Unexpected token #{inspect(value)} (#{type}) at position #{pos}")

  @spec syntax!(String.t()) :: no_return()
  defp syntax!(message), do: throw({:jmespath, "syntax", message})
end

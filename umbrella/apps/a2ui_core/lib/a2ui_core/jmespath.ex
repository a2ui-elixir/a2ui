defmodule A2UICore.JMESPath do
  @moduledoc """
  [JMESPath](https://jmespath.org/specification.html) queries over JSON
  data: the engine behind the MCP catalog's `jmespath` function.

  It implements the specification — field and index access, slices,
  list, object, flatten and filter projections, multi-select lists and
  hashes, pipes, `||`, `&&`, `!`, comparisons, literals, raw strings,
  expression references and every built-in function — and agrees with
  the JMESPath compliance suite.

      iex> A2UICore.JMESPath.search("people[?age > `30`].name", %{
      ...>   "people" => [%{"name" => "Ada", "age" => 36}, %{"name" => "Alan", "age" => 29}]
      ...> })
      {:ok, ["Ada"]}
      iex> A2UICore.JMESPath.search("sort_by(items, &price)[0].id", %{
      ...>   "items" => [%{"id" => "b", "price" => 3}, %{"id" => "a", "price" => 1}]
      ...> })
      {:ok, "a"}

  A malformed expression, a function called with the wrong number or
  types of arguments, and an unknown function are errors with category
  `:expression` and the codes `JMESPATH_SYNTAX`, `JMESPATH_INVALID_ARITY`,
  `JMESPATH_INVALID_TYPE`, `JMESPATH_INVALID_VALUE` and
  `JMESPATH_UNKNOWN_FUNCTION`.

      iex> {:error, error} = A2UICore.JMESPath.search("foo[", %{})
      iex> error.code
      "JMESPATH_SYNTAX"

  JSON objects are Elixir maps, so `keys/1` and `values/1` return their
  entries in map order; the specification leaves that order open.
  """

  alias A2UICore.Error
  alias A2UICore.JMESPath.{Interpreter, Parser}

  @moduledoc since: "0.1.0"

  @doc "Evaluates `expression` against `data`."
  @spec search(String.t(), term()) :: {:ok, term()} | {:error, Error.t()}
  def search(expression, data) when is_binary(expression) do
    case Interpreter.visit(Parser.parse(expression), data) do
      {:expref, _node} -> {:ok, nil}
      result -> {:ok, result}
    end
  catch
    {:jmespath, kind, message} ->
      code = "JMESPATH_" <> (kind |> String.upcase() |> String.replace("-", "_"))
      {:error, Error.new(:expression, code, message)}
  end
end

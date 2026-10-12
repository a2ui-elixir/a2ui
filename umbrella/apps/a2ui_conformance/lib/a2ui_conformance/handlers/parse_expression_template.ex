defmodule A2UIConformance.Handlers.ParseExpressionTemplate do
  @moduledoc false

  # `parse_expression_template` (reference harness L1702-1733): parses
  # `input` and compares the parts — adjacent literal strings joined,
  # empty strings dropped — with `expect`. A case with `expect_error`
  # must fail: the category defaults to `ParseError`, and the message is
  # matched as a regular expression only (no substring or synonym
  # fallbacks, unlike the shared error matcher).

  @behaviour A2UIConformance.Handler

  import ExUnit.Assertions

  alias A2UIConformance.{Case, Matchers}
  alias A2UICore.Expression

  @impl true
  def run(%Case{raw: raw}, _context) do
    input = raw["input"] || ""
    expect_error = raw["expect_error"] || raw["expectError"]

    case {Expression.parse(input), expect_error} do
      {{:ok, parts}, nil} ->
        Matchers.assert_json_equal(raw["expect"] || [], join_literals(parts), "parts")
        :ok

      {{:ok, parts}, _expected} ->
        flunk("expected an error, got #{inspect(parts)}")

      {{:error, error}, nil} ->
        flunk("unexpected error: #{error.message}")

      {{:error, error}, expected} ->
        assert_error(expected, error)
        :ok
    end
  end

  defp assert_error(expected, error) do
    category = expected["category"] || "ParseError"
    Matchers.assert_error(%{"category" => category}, error)

    if pattern = expected["message"] do
      assert Regex.match?(Regex.compile!(pattern), error.message),
             "expected message matching #{inspect(pattern)}, got #{inspect(error.message)}"
    end
  end

  defp join_literals(parts) do
    parts
    |> Enum.reduce([], fn
      part, [previous | rest] when is_binary(part) and is_binary(previous) ->
        [previous <> part | rest]

      part, acc ->
        [part | acc]
    end)
    |> Enum.reverse()
    |> Enum.reject(&(&1 == ""))
  end
end

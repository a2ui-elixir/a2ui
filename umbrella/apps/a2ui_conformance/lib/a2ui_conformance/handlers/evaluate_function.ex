defmodule A2UIConformance.Handlers.EvaluateFunction do
  @moduledoc false

  # `evaluate_function` (reference harness L1786-1822): runs the named
  # function of the case's first catalog with `args` against a surface
  # holding `dataModel` and compares the result with `expect` (exact
  # equality) or, with `expectError`, requires a matching error.
  #
  # A function the catalog implements is executed directly, so its
  # errors surface; any other call goes through dynamic-value
  # resolution, where failures are reported as effects.

  @behaviour A2UIConformance.Handler

  import ExUnit.Assertions

  alias A2UIConformance.{Case, CatalogFixtures, Matchers}
  alias A2UICore.Resolution.DataContext
  alias A2UICore.State.DataModel

  @impl true
  def run(%Case{raw: raw} = test_case, _context) do
    {:ok, [default | _] = catalogs} = CatalogFixtures.for_case(test_case)
    name = raw["function"]
    args = raw["args"]
    expect_error = raw["expectError"] || raw["expect_error"]

    context =
      DataContext.new("/",
        data_model: DataModel.new(raw["dataModel"] || %{}),
        catalog: default,
        catalogs: Map.new(catalogs, &{&1.catalog_id, &1}),
        locale: raw["locale"] || "en-US"
      )

    outcome = invoke(default, name, args, context)

    case {outcome, expect_error} do
      {{:ok, value}, nil} ->
        Matchers.assert_json_equal(raw["expect"], value, "result of #{name}")
        :ok

      {{:error, error}, nil} ->
        flunk("#{name} failed: #{Exception.message(error)}")

      {{:error, error}, expected} ->
        Matchers.assert_error(expected, error)
        :ok

      {{:ok, value}, _expected} ->
        flunk("expected an error from #{name}, got #{inspect(value)}")
    end
  end

  defp invoke(catalog, name, args, context) do
    case Map.get(catalog.functions, name) do
      %{execute: execute} when is_function(execute, 2) ->
        case execute.(args, context) do
          {:ok, value} -> {:ok, value}
          {:ok, value, _effects} -> {:ok, value}
          {:error, error} -> {:error, error}
        end

      _not_executable ->
        {value, _effects} =
          DataContext.resolve_dynamic_value(context, %{"call" => name, "args" => args})

        {:ok, value}
    end
  end
end

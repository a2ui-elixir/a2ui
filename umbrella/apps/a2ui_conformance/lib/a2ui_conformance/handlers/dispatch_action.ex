defmodule A2UIConformance.Handlers.DispatchAction do
  @moduledoc false

  # `dispatch_action` (reference harness L1736-1783): the action payload
  # is resolved in a data context at `scope` over `dataModel`; a resolved
  # event (or name shorthand) is dispatched from component `test_comp`.
  # `expectDispatched` is compared on `name`, `context` and
  # `userMessage`; `expectDataModel` against the final model.

  @behaviour A2UIConformance.Handler

  import ExUnit.Assertions

  alias A2UIConformance.{Case, CatalogFixtures, Matchers}
  alias A2UICore.Error
  alias A2UICore.Resolution.DataContext
  alias A2UICore.State.Surface

  @impl true
  def run(%Case{raw: raw} = test_case, _context) do
    {:ok, [default | _] = catalogs} = CatalogFixtures.for_case(test_case)

    surface =
      Surface.new(raw["surfaceId"] || "main",
        catalog_id: default.catalog_id,
        catalogs: Map.new(catalogs, &{&1.catalog_id, &1}),
        data_model: raw["dataModel"] || %{}
      )

    context = DataContext.for_surface(surface, path: raw["scope"] || "/")
    {resolved, effects} = DataContext.resolve_action(context, raw["actionPayload"])

    case {raw["expectError"], first_error(effects)} do
      {nil, _error} ->
        assert_dispatched(surface, resolved, raw)

      {expected, nil} ->
        flunk("expected an error matching #{inspect(expected)}, but the action resolved")

      {expected, error} ->
        Matchers.assert_error(expected, error)
    end

    :ok
  end

  defp first_error(effects) do
    Enum.find_value(effects, fn
      {:error, payload} -> Error.new(:expression, "EXPRESSION_ERROR", payload[:message] || "")
      _warning -> nil
    end)
  end

  defp assert_dispatched(surface, resolved, raw) do
    event =
      if is_map(resolved) and (Map.has_key?(resolved, "event") or Map.has_key?(resolved, "name")),
        do: Surface.dispatch_action(surface, resolved, "test_comp")

    case raw["expectDispatched"] do
      nil ->
        :ok

      expected ->
        assert event != nil, "expected the action to be dispatched, but none was"

        for key <- ["name", "context", "userMessage"], Map.has_key?(expected, key) do
          Matchers.assert_json_equal(expected[key], event[key], "dispatched #{key}")
        end
    end

    if Map.has_key?(raw, "expectDataModel") do
      {:ok, data} = Surface.get_data(surface, "/")
      Matchers.assert_json_equal(raw["expectDataModel"], data, "data model")
    end
  end
end

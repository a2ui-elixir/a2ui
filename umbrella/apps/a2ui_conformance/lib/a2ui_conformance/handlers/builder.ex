defmodule A2UIConformance.Handlers.Builder do
  @moduledoc false

  # The cases of conformance/agent/builder/builder.yaml
  # (python/a2ui_agent/tests/conformance/builder_suite.py): the case's
  # builder AST, flattened with the basic catalog and packaged as v0.9
  # messages, must equal its golden file, and the golden file must pass
  # a renderer's validation with the case's relaxations.

  @behaviour A2UIConformance.Handler

  alias A2UIAgent.Builder
  alias A2UIConformance.{Case, GoldenSuites, Matchers}
  alias A2UICore.Catalog.Basic

  @version "v0.9"

  @impl true
  def run(%Case{suite: suite, raw: raw}, _context) do
    catalog = Basic.catalog("v0.9.1")

    messages =
      raw["input"]
      |> GoldenSuites.ast()
      |> Builder.messages(
        surface_id: raw["surface_id"],
        catalog_id: raw["catalog_id"],
        data_model: raw["data_model"],
        root_id: raw["root_id"],
        catalog: catalog,
        version: @version
      )

    golden = GoldenSuites.golden(suite, raw["golden"])
    Matchers.assert_json_equal(golden, messages, "builder output")
    GoldenSuites.assert_valid(golden, raw, [catalog])
    :ok
  end
end

defmodule A2UICore.SpecCasesTest do
  @moduledoc false
  # The upstream specification's own test cases
  # (`specification/{v0_9_1,v1_0}/test/cases/*.json`) are calibrated
  # against ajv with the real catalogs bound. This suite replays every
  # case through `A2UICore.Schema` — the same binding the upstream
  # `run_tests.py` performs (catalog `$id` aliased to `catalog.json`).
  # It is the strongest wire-fidelity signal for the validator.
  #
  # Skipped silently when the upstream checkout is absent.

  use ExUnit.Case, async: true

  alias A2UICore.Schema
  alias A2UICore.Schema.Source

  @reference_spec_dir "../../../../reference/a2ui/specification"

  @schema_names %{
    "agent_to_renderer.json" => :agent_to_renderer,
    "server_to_client.json" => :agent_to_renderer,
    "renderer_to_agent.json" => :renderer_to_agent,
    "client_to_server.json" => :renderer_to_agent,
    "common_types.json" => :common_types
  }

  @spec_dirs ["v1_0", "v0_9_1"]

  for dir <- @spec_dirs,
      version = String.replace(dir, "_", "."),
      path = Path.expand(@reference_spec_dir, __DIR__),
      file <- (File.dir?(path) && Path.wildcard(Path.join([path, dir, "test/cases/*.json"])) || []) do
    @external_resource file

    suite = Jason.decode!(File.read!(file))
    schema_version = version

    describe "#{dir}/#{Path.basename(file)}" do
      for test_case <- suite["tests"] do
        @tag :spec_case
        test "#{test_case["description"]}" do
          suite = unquote(Macro.escape(suite))
          test_case = unquote(Macro.escape(test_case))
          version = unquote(schema_version)

          schema = schema_for(version, suite["schema"])
          catalog = catalog_for(version, suite["catalog"])

          registry = %{
            "common_types.json" => Source.document(version, :common_types),
            "catalog.json" => catalog
          }

          result = Schema.validate(test_case["data"], schema, registry: registry, root: schema)
          expected = unquote(Macro.escape(test_case["valid"]))

          if expected do
            assert :ok = result
          else
            assert {:error, details} = result
            assert details != []
          end
        end
      end
    end
  end

  defp schema_for(version, name) do
    logical = Map.fetch!(@schema_names, name)
    Source.document(version, logical)
  end

  defp catalog_for(_version, "testing_catalog.json"), do: Source.catalog("v1.0", :testing)
  defp catalog_for("v1.0", _default), do: Source.catalog("v1.0", :basic)
  defp catalog_for(_v0_9, _default), do: Source.catalog("v0.9.1", :basic)
end
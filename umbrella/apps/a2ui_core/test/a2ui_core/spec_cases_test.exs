defmodule A2UICore.SpecCasesTest do
  @moduledoc false
  # The upstream specification's own test cases
  # (`specification/{v0_9_1,v1_0}/test/cases/*.json`) are calibrated
  # against ajv with the real catalogs bound. This suite replays every
  # case through `A2UICore.Schema` with the same registry the upstream
  # `run_tests.py` passes to ajv (catalog `$id` aliased to `catalog.json`).
  # It is the strongest wire-fidelity signal for the validator.
  #
  # Generates no tests when the upstream checkout is absent; the
  # reference guard test makes that visible.

  use ExUnit.Case, async: true

  alias A2UICore.Schema
  alias A2UICore.Schema.Source
  alias A2UICore.Test.Reference

  # ajv ships the 2020-12 meta-schemas; catalog_definition.json references
  # them for the JSON-Schema-valued fields of a catalog. These are the
  # json-schema.org copies (test/fixtures/json_schema, with their license),
  # by `$id`.
  @meta_schemas "../fixtures/json_schema/**/*.json"
                |> Path.expand(__DIR__)
                |> Path.wildcard()
                |> Map.new(fn file ->
                  @external_resource file
                  schema = file |> File.read!() |> Jason.decode!()
                  {schema["$id"], schema}
                end)

  @schema_names %{
    "agent_to_renderer.json" => :agent_to_renderer,
    "server_to_client.json" => :agent_to_renderer,
    "renderer_to_agent.json" => :renderer_to_agent,
    "client_to_server.json" => :renderer_to_agent,
    "common_types.json" => :common_types,
    "catalog_definition.json" => :catalog_definition
  }

  for {dir, version, file} <- Reference.spec_case_files() do
    @external_resource file

    suite = file |> File.read!() |> Jason.decode!()
    schema_name = Map.get(suite, "schema", "agent_to_renderer.json")
    catalog_name = suite["catalog"]

    describe "#{dir}/#{Path.basename(file)}" do
      for {test_case, index} <- Enum.with_index(suite["tests"]) do
        verdict = if Map.get(test_case, "valid", true), do: :valid, else: :invalid

        @tag :spec_case
        test "##{index} #{test_case["description"]}" do
          version = unquote(version)
          data = unquote(Macro.escape(test_case["data"]))
          schema = schema_for(version, unquote(schema_name))

          # ajv runs with ajv-formats, so `format` is asserted here.
          result =
            Schema.validate(data, schema,
              registry: registry(version, unquote(catalog_name)),
              root: schema,
              formats: :assert
            )

          assert_verdict(unquote(verdict), result)
        end
      end
    end
  end

  # run_tests.py step 3: the shipped v1.0 catalogs are structurally valid
  # catalog documents.
  describe "catalog structure against catalog_definition.json (v1.0)" do
    for kind <- [:basic, :testing] do
      @tag :spec_case
      test "#{kind} catalog" do
        validator = %{"$ref" => "https://a2ui.org/specification/v1_0/catalog_definition.json"}

        registry = %{
          "catalog_definition.json" => Source.document("v1.0", :catalog_definition),
          "common_types.json" => Source.document("v1.0", :common_types)
        }

        registry = Map.merge(registry, @meta_schemas)

        catalog = Source.catalog("v1.0", unquote(kind))

        assert :ok =
                 Schema.validate(catalog, validator,
                   registry: registry,
                   root: validator,
                   formats: :assert
                 )
      end
    end
  end

  # The meta-schemas are live: a component whose schema is not a JSON
  # Schema fails the catalog structure check.
  @tag :spec_case
  test "catalog structure rejects a component schema that is not a JSON Schema" do
    validator = %{"$ref" => "https://a2ui.org/specification/v1_0/catalog_definition.json"}

    registry =
      Map.merge(
        %{
          "catalog_definition.json" => Source.document("v1.0", :catalog_definition),
          "common_types.json" => Source.document("v1.0", :common_types)
        },
        @meta_schemas
      )

    catalog = put_in(Source.catalog("v1.0", :basic), ["components", "Text", "type"], 5)

    assert {:error, [_ | _]} =
             Schema.validate(catalog, validator, registry: registry, root: validator)
  end

  # run_tests.py steps 6-7: the bundle and A2A schemas resolve all their
  # references and accept the upstream minimal payloads.
  describe "sample and A2A schemas (v1.0)" do
    @basic_id "https://a2ui.org/specification/v1_0/catalogs/basic/catalog.json"

    @a2a_payloads [
      {"sample.json",
       %{
         "name" => "Test Sample",
         "description" => "A minimal sample for testing schema integrity",
         "messages" => [
           %{
             "version" => "v1.0",
             "createSurface" => %{"surfaceId" => "test_surface", "catalogId" => @basic_id}
           }
         ]
       }},
      {"renderer_capabilities.json",
       %{"v1.0" => %{"supportedCatalogIds" => [@basic_id], "inlineCatalogs" => []}}},
      {"agent_capabilities.json",
       %{"v1.0" => %{"supportedCatalogIds" => [@basic_id], "acceptsInlineCatalogs" => true}}},
      {"renderer_data_model.json",
       %{"version" => "v1.0", "surfaces" => %{"surface_123" => %{"user" => %{"name" => "Alice"}}}}},
      {"agent_to_renderer_list_wrapper.json",
       %{
         "messages" => [
           %{
             "version" => "v1.0",
             "createSurface" => %{"surfaceId" => "test_surface", "catalogId" => @basic_id}
           }
         ]
       }},
      {"renderer_to_agent_list_wrapper.json",
       %{
         "messages" => [
           %{
             "version" => "v1.0",
             "action" => %{
               "name" => "click_button",
               "surfaceId" => "test_surface",
               "sourceComponentId" => "btn_1",
               "timestamp" => "2026-06-22T17:00:00Z",
               "context" => %{}
             }
           }
         ]
       }}
    ]

    for {name, payload} <- @a2a_payloads do
      @tag :spec_case
      test name do
        schema = Source.document("v1.0", unquote(name))

        assert :ok =
                 Schema.validate(unquote(Macro.escape(payload)), schema,
                   registry: all_v1_documents(),
                   root: schema,
                   formats: :assert
                 )
      end
    end
  end

  defp all_v1_documents do
    dir = Path.join(Source.priv_dir(), "schemas/v1_0")

    dir
    |> File.ls!()
    |> Map.new(fn file -> {file, Source.document("v1.0", file)} end)
    |> Map.merge(%{"catalog.json" => Source.catalog("v1.0", :basic)})
    |> Map.merge(@meta_schemas)
  end

  defp assert_verdict(:valid, result), do: assert(:ok = result)
  defp assert_verdict(:invalid, result), do: assert({:error, [_ | _]} = result)

  defp schema_for(version, name), do: Source.document(version, Map.fetch!(@schema_names, name))

  defp registry(version, catalog_name) do
    base = %{
      "common_types.json" => Source.document(version, :common_types),
      "catalog.json" => catalog_for(version, catalog_name),
      "agent_to_renderer.json" => Source.document(version, :agent_to_renderer),
      "renderer_to_agent.json" => Source.document(version, :renderer_to_agent)
    }

    case Source.document(version, :catalog_definition) do
      nil -> base
      definition -> Map.put(base, "catalog_definition.json", definition)
    end
    |> Map.merge(@meta_schemas)
  end

  defp catalog_for("v1.0", "testing_catalog.json"), do: Source.catalog("v1.0", :testing)
  defp catalog_for("v1.0", nil), do: Source.catalog("v1.0", :basic)
  defp catalog_for("v0.9.1", nil), do: Source.catalog("v0.9.1", :basic)
end

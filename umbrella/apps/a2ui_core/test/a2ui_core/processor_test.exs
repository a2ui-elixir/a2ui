defmodule A2UICore.ProcessorTest do
  @moduledoc false
  use ExUnit.Case, async: true

  alias A2UICore.Catalog
  alias A2UICore.Catalog.Basic
  alias A2UICore.Error
  alias A2UICore.Message.Operation.{CreateSurface, UpdateDataModel}
  alias A2UICore.Processor
  alias A2UICore.State.{Components, Surface}
  alias A2UICore.Validation.Config

  setup_all do
    {:ok, v09: Basic.catalog("v0.9.1"), v10: Basic.catalog("v1.0")}
  end

  defp message_version(%{protocol_version: "v1.0"}), do: "v1.0"
  defp message_version(_catalog), do: "v0.9"

  defp create(catalog, surface_id, extra \\ %{}) do
    %{
      "version" => message_version(catalog),
      "createSurface" =>
        Map.merge(%{"surfaceId" => surface_id, "catalogId" => catalog.catalog_id}, extra)
    }
  end

  defp update_components(version, surface_id, components) do
    %{
      "version" => version,
      "updateComponents" => %{"surfaceId" => surface_id, "components" => components}
    }
  end

  defp ready(catalog, options \\ []) do
    processor = Processor.new([catalog], options)
    {:ok, processor, _effects} = Processor.process(processor, create(catalog, "s"))
    processor
  end

  defp failure(result) do
    assert {:error, %Error{} = error, processor} = result
    {error, processor}
  end

  describe "new/2" do
    test "raises without catalogs" do
      assert_raise ArgumentError, "At least one catalog must be provided.", fn ->
        Processor.new([])
      end
    end

    test "starts without surfaces", %{v09: catalog} do
      processor = Processor.new([catalog])

      assert Processor.surfaces(processor) == []
      assert Processor.surface(processor, "s") == nil
    end
  end

  describe "createSurface" do
    test "creates the surface on the named catalog", %{v09: v09, v10: v10} do
      processor = Processor.new([v09, v10])

      assert {:ok, processor, [{:surface_created, "s"}]} =
               Processor.process(processor, create(v10, "s", %{"sendDataModel" => true}))

      surface = Processor.surface(processor, "s")
      assert surface.catalog_id == v10.catalog_id
      assert surface.send_data_model == true
      assert surface.root_id == "root"
      assert Map.keys(surface.catalogs) == [v10.catalog_id]
    end

    test "defaults to the first catalog when none is named", %{v09: v09, v10: v10} do
      processor = Processor.new([v10, v09])
      operation = %CreateSurface{surface_id: "s", version: "v1.0"}

      assert {:ok, processor, [{:surface_created, "s"}]} =
               Processor.apply_operation(processor, operation)

      assert Processor.surface(processor, "s").catalog_id == v10.catalog_id
    end

    test "a root other than \"root\"", %{v10: v10} do
      processor = Processor.new([v10], validation: Config.strict())
      operation = %CreateSurface{surface_id: "s", catalog_id: v10.catalog_id, root: "top"}

      assert {:ok, processor, _effects} = Processor.apply_operation(processor, operation)
      assert Processor.surface(processor, "s").root_id == "top"

      batch = [%{"id" => "top", "component" => "Text", "text" => "a"}]

      assert {:ok, _processor, [{:components_updated, "s", ["top"]}]} =
               Processor.process(processor, update_components("v1.0", "s", batch))
    end

    test "decoded inline data lands before inline components", %{v10: v10} do
      processor = Processor.new([v10])

      operation = %CreateSurface{
        surface_id: "s",
        catalog_id: v10.catalog_id,
        data_model: %{"n" => 1},
        components: [%{"id" => "root", "component" => "Text", "text" => "a"}]
      }

      assert {:ok, _processor, effects} = Processor.apply_operation(processor, operation)

      assert effects == [
               {:surface_created, "s"},
               {:data_model_updated, "s", "/"},
               {:components_updated, "s", ["root"]}
             ]
    end

    test "an inline v1.0 createSurface is decoded into create, components, data", %{v10: v10} do
      processor = Processor.new([v10], validation: Config.strict())

      message =
        create(v10, "s", %{
          "dataModel" => %{"n" => 1},
          "components" => [%{"id" => "root", "component" => "Text", "text" => %{"@path" => "/n"}}]
        })

      assert {:ok, processor, effects} = Processor.process(processor, message)

      assert effects == [
               {:surface_created, "s"},
               {:components_updated, "s", ["root"]},
               {:data_model_updated, "s", "/"}
             ]

      assert {:ok, %{"n" => 1}} =
               Surface.get_data(Processor.surface(processor, "s"), "/")
    end

    test "a duplicate surface id", %{v09: v09} do
      processor = ready(v09)
      {error, ^processor} = failure(Processor.process(processor, create(v09, "s")))

      assert error.category == :integrity
      assert error.message == "Surface s already exists."
    end

    test "an unknown catalog", %{v09: v09} do
      processor = Processor.new([v09])

      message = %{
        "version" => "v0.9",
        "createSurface" => %{"surfaceId" => "s", "catalogId" => "urn:none"}
      }

      {error, _processor} = failure(Processor.process(processor, message))

      assert error.category == :catalog
      assert error.message == "Catalog not found: urn:none"
    end

    test "a catalog of another protocol version", %{v09: v09, v10: v10} do
      processor = Processor.new([v09, v10])

      message = %{
        "version" => "v0.9",
        "createSurface" => %{"surfaceId" => "s", "catalogId" => v10.catalog_id}
      }

      {error, processor} = failure(Processor.process(processor, message))

      assert error.code == "VERSION_MISMATCH"
      assert error.message =~ "does not match message protocol version (v0.9)"
      assert Processor.surfaces(processor) == []
    end

    test "an invalid theme", %{v09: v09} do
      processor = Processor.new([v09])

      message = create(v09, "s", %{"theme" => %{"primaryColor" => 7}})
      {error, processor} = failure(Processor.process(processor, message))

      assert error.message =~ "Validation failed for theme on surface 's'"
      assert Processor.surfaces(processor) == []
    end

    test "a valid theme is kept", %{v09: v09} do
      processor = Processor.new([v09])

      assert {:ok, processor, _effects} =
               Processor.process(
                 processor,
                 create(v09, "s", %{"theme" => %{"primaryColor" => "#00AAFF"}})
               )

      assert Processor.surface(processor, "s").theme == %{"primaryColor" => "#00AAFF"}
    end
  end

  describe "updateComponents" do
    test "adds components", %{v09: v09} do
      processor = ready(v09, validation: Config.strict())

      message =
        update_components("v0.9", "s", [%{"id" => "root", "component" => "Text", "text" => "hi"}])

      assert {:ok, processor, [{:components_updated, "s", ["root"]}]} =
               Processor.process(processor, message)

      component =
        Components.get(Processor.surface(processor, "s").components, "root")

      assert component.type == "Text"
      assert component.props == %{"text" => "hi"}
    end

    test "a later update keeps the type and replaces the properties", %{v09: v09} do
      processor = ready(v09)

      {:ok, processor, _} =
        Processor.process(
          processor,
          update_components("v0.9", "s", [%{"id" => "root", "component" => "Text", "text" => "a"}])
        )

      {:ok, processor, _} =
        Processor.process(
          processor,
          update_components("v0.9", "s", [%{"id" => "root", "text" => "b"}])
        )

      component =
        Components.get(Processor.surface(processor, "s").components, "root")

      assert {component.type, component.props} == {"Text", %{"text" => "b"}}
    end

    test "an unknown surface", %{v09: v09} do
      processor = Processor.new([v09])

      {error, _processor} =
        failure(
          Processor.process(
            processor,
            update_components("v0.9", "nope", [
              %{"id" => "a", "component" => "Text", "text" => "x"}
            ])
          )
        )

      assert error.category == :integrity
      assert error.message == "Surface not found for message: nope"
    end

    test "a component without id or type", %{v09: v09} do
      processor = ready(v09)

      {error, _} =
        failure(
          Processor.process(processor, update_components("v0.9", "s", [%{"component" => "Text"}]))
        )

      assert error.message =~ "missing an 'id'"

      {error, _} =
        failure(Processor.process(processor, update_components("v0.9", "s", [%{"id" => "x"}])))

      assert error.message == "Cannot create component x without a type."
    end

    test "a component naming an unknown catalog", %{v09: v09} do
      processor = ready(v09)
      component = %{"id" => "x", "component" => "Text", "text" => "a", "catalogId" => "urn:none"}

      {error, _} =
        failure(Processor.process(processor, update_components("v0.9", "s", [component])))

      assert error.category == :catalog
    end

    test "a component of a catalog with another protocol version", %{v09: v09, v10: v10} do
      processor = Processor.new([v09, v10])
      {:ok, processor, _} = Processor.process(processor, create(v09, "s"))

      component = %{
        "id" => "x",
        "component" => "Text",
        "text" => "a",
        "catalogId" => v10.catalog_id
      }

      {error, _} =
        failure(Processor.process(processor, update_components("v0.9", "s", [component])))

      assert error.category == :catalog
      assert error.message =~ "has different protocol version"
    end

    test "a failing batch leaves the surface untouched", %{v09: v09} do
      processor = ready(v09, validation: Config.strict())

      batch = [
        %{"id" => "root", "component" => "Column", "children" => ["child"]},
        %{"id" => "child", "component" => "Text", "text" => 5}
      ]

      {error, processor} =
        failure(Processor.process(processor, update_components("v0.9", "s", batch)))

      assert error.category == :validation
      assert Components.size(Processor.surface(processor, "s").components) == 0
    end

    test "dangling references are an integrity error when validating", %{v09: v09} do
      processor = ready(v09, validation: Config.strict())
      batch = [%{"id" => "root", "component" => "Column", "children" => ["gone"]}]
      {error, _} = failure(Processor.process(processor, update_components("v0.9", "s", batch)))

      assert error.category == :integrity
      assert error.message =~ "Dangling reference"
    end

    test "without a validation configuration batches are committed unchecked", %{v09: v09} do
      processor = ready(v09)
      batch = [%{"id" => "root", "component" => "Column", "children" => ["gone"]}]

      assert {:ok, _processor, [{:components_updated, "s", ["root"]}]} =
               Processor.process(processor, update_components("v0.9", "s", batch))
    end

    test "a relaxed configuration tolerates a missing root", %{v09: v09} do
      processor = ready(v09, validation: Config.relaxed())
      batch = [%{"id" => "x", "component" => "Text", "text" => "a"}]

      assert {:ok, _processor, _effects} =
               Processor.process(processor, update_components("v0.9", "s", batch))
    end
  end

  describe "updateDataModel and deleteSurface" do
    test "writes at a path and at the root", %{v09: v09} do
      processor = ready(v09)

      {:ok, processor, [{:data_model_updated, "s", "/a"}]} =
        Processor.process(processor, %{
          "version" => "v0.9",
          "updateDataModel" => %{"surfaceId" => "s", "path" => "/a", "value" => 1}
        })

      {:ok, processor, [{:data_model_updated, "s", "/"}]} =
        Processor.process(processor, %{
          "version" => "v0.9",
          "updateDataModel" => %{"surfaceId" => "s", "value" => %{"b" => 2}}
        })

      assert {:ok, %{"b" => 2}} =
               Surface.get_data(Processor.surface(processor, "s"), "/")
    end

    test "an invalid path is an error and changes nothing", %{v09: v09} do
      processor = ready(v09)

      {error, ^processor} =
        failure(
          Processor.process(processor, %{
            "version" => "v0.9",
            "updateDataModel" => %{"surfaceId" => "s", "path" => "/__proto__/x", "value" => 1}
          })
        )

      assert error.category == :data
    end

    test "an unknown surface", %{v09: v09} do
      processor = Processor.new([v09])

      {error, _} =
        failure(
          Processor.process(processor, %{
            "version" => "v0.9",
            "updateDataModel" => %{"surfaceId" => "nope", "value" => 1}
          })
        )

      assert error.message == "Surface not found for message: nope"
    end

    test "deleteSurface removes it; an unknown id is ignored", %{v09: v09} do
      processor = ready(v09)
      delete = fn id -> %{"version" => "v0.9", "deleteSurface" => %{"surfaceId" => id}} end

      assert {:ok, processor, [{:surface_deleted, "s"}]} =
               Processor.process(processor, delete.("s"))

      assert Processor.surfaces(processor) == []
      assert {:ok, ^processor, []} = Processor.process(processor, delete.("s"))
    end
  end

  describe "set_data/4" do
    test "a renderer-side write lands in the data model", %{v10: v10} do
      processor = ready(v10)

      assert {:ok, processor, [{:data_model_updated, "s", "/form/name"}]} =
               Processor.set_data(processor, "s", "/form/name", "Ada")

      assert {:ok, %{"form" => %{"name" => "Ada"}}} =
               Surface.get_data(Processor.surface(processor, "s"), "/")
    end

    test "is not subject to the agent's allowed messages", %{v10: v10} do
      config = %{Config.strict() | allowed_messages: ["createSurface"]}
      processor = ready(v10, validation: config)

      assert {:ok, _processor, [{:data_model_updated, "s", "/x"}]} =
               Processor.set_data(processor, "s", "/x", 1)
    end

    test "an unknown surface or a forbidden path is an error", %{v10: v10} do
      processor = ready(v10)

      assert {:error, %Error{message: "Surface not found for message: nope"}} =
               Processor.set_data(processor, "nope", "/x", 1)

      assert {:error, %Error{category: :data}} =
               Processor.set_data(processor, "s", "/__proto__/x", 1)
    end
  end

  describe "process/2 payload shapes" do
    test "lists and wrappers are applied in order", %{v09: v09} do
      processor = Processor.new([v09])

      messages = [
        create(v09, "a"),
        %{"version" => "v0.9", "deleteSurface" => %{"surfaceId" => "a"}},
        create(v09, "b")
      ]

      assert {:ok, processor, effects} = Processor.process(processor, %{"messages" => messages})

      assert effects == [
               {:surface_created, "a"},
               {:surface_deleted, "a"},
               {:surface_created, "b"}
             ]

      assert Enum.map(Processor.surfaces(processor), & &1.id) == ["b"]
    end

    test "a failure keeps what was applied before it", %{v09: v09} do
      processor = Processor.new([v09])

      messages = [
        create(v09, "a"),
        %{"version" => "v0.9", "updateDataModel" => %{"surfaceId" => "missing", "value" => 1}},
        create(v09, "b")
      ]

      {error, processor} = failure(Processor.process(processor, messages))

      assert error.message =~ "Surface not found"
      assert Enum.map(Processor.surfaces(processor), & &1.id) == ["a"]
    end

    test "an undecodable payload is returned as an error with the processor unchanged", %{
      v09: v09
    } do
      processor = Processor.new([v09])
      {error, ^processor} = failure(Processor.process(processor, %{"version" => "v0.9"}))

      assert %Error{} = error
    end

    test "surfaces are sorted by id", %{v09: v09} do
      processor = Processor.new([v09])
      {:ok, processor, _} = Processor.process(processor, [create(v09, "b"), create(v09, "a")])

      assert Enum.map(Processor.surfaces(processor), & &1.id) == ["a", "b"]
    end
  end

  describe "RPC operations" do
    defp media_catalog do
      function = fn name, extra ->
        Map.merge(
          %{
            "type" => "object",
            "properties" => %{"@call" => %{"const" => name}, "args" => %{"type" => "object"}},
            "required" => ["@call"]
          },
          extra
        )
      end

      document = %{
        "catalogId" => "media",
        "components" => %{},
        "functions" => %{
          "playMedia" => function.("playMedia", %{"allowedCallers" => "rendererOrAgent"}),
          "unlock" =>
            function.("unlock", %{
              "allowedCallers" => "agentOnly",
              "requiresUserActivation" => true
            })
        }
      }

      document
      |> Catalog.from_json!(protocol_version: "v1.0")
      |> Catalog.put_implementations(%{
        "playMedia" => fn args, _context -> {:ok, %{"playing" => args["mediaId"]}} end,
        "unlock" => fn _args, _context -> {:ok, nil} end
      })
    end

    defp call_message(name, catalog_id \\ nil) do
      call = %{"@call" => name, "args" => %{"mediaId" => "m1"}}
      call = if catalog_id, do: Map.put(call, "catalogId", catalog_id), else: call

      %{
        "version" => "v1.0",
        "callRendererFunction" => %{"functionCallId" => "c1", "callFunction" => call}
      }
    end

    defp response_of(effects) do
      assert [{:rpc_response, %{"rendererFunctionResponse" => response}}] = effects
      response
    end

    test "a renderer function call is answered with a response effect" do
      processor = ready(media_catalog())

      assert {:ok, ^processor, effects} =
               Processor.process(processor, call_message("playMedia", "media"))

      assert %{"functionCallId" => "c1", "value" => %{"playing" => "m1"}} = response_of(effects)
    end

    test "the wire format requires the call to name its catalog" do
      processor = ready(media_catalog())

      {error, ^processor} = failure(Processor.process(processor, call_message("playMedia")))
      assert error.message =~ "catalogId"
    end

    test "an unknown catalog or function is an error response" do
      processor = ready(media_catalog())

      assert {:ok, _processor, effects} =
               Processor.process(processor, call_message("playMedia", "elsewhere"))

      assert %{"error" => %{"code" => "INVALID_FUNCTION_CALL", "message" => message}} =
               response_of(effects)

      assert message == "Catalog not found: elsewhere"

      assert {:ok, _processor, effects} =
               Processor.process(processor, call_message("nope", "media"))

      assert %{"error" => %{"message" => "Function not found: nope"}} = response_of(effects)
    end

    test "user activation is an option of the call" do
      processor = ready(media_catalog())

      message = call_message("unlock", "media")

      assert {:ok, _processor, effects} = Processor.process(processor, message)
      assert %{"error" => %{"message" => text}} = response_of(effects)
      assert text =~ "requires user activation"

      assert {:ok, _processor, effects} =
               Processor.process(processor, message, user_activated: true)

      assert %{"functionCallId" => "c1", "value" => nil} = response_of(effects)
    end

    test "the call runs whether or not a surface is named" do
      processor = ready(media_catalog())
      message = call_message("playMedia", "media")

      for options <- [[surface_id: "s"], [surface_id: "other"], []] do
        assert {:ok, _processor, effects} = Processor.process(processor, message, options)
        assert %{"value" => %{"playing" => "m1"}} = response_of(effects)
      end
    end

    test "agent calls are registered, answered and settled", %{v10: v10} do
      processor = Processor.new([v10])
      call = %{"@call" => "queryInventory", "catalogId" => v10.catalog_id, "args" => %{}}

      assert {:ok, processor, message} =
               Processor.call_agent_function(processor, "s", call,
                 function_call_id: "q1",
                 timeout_ms: 500
               )

      assert %{"callAgentFunction" => %{"functionCallId" => "q1", "surfaceId" => "s"}} = message
      assert Processor.agent_call_timeout(processor, "q1") == 500

      answer = %{
        "version" => "v1.0",
        "agentFunctionResponse" => %{"functionCallId" => "q1", "value" => %{"inStock" => 12}}
      }

      assert {:ok, processor, [{:rpc_settled, "q1", {:ok, %{"inStock" => 12}}}]} =
               Processor.process(processor, answer)

      assert Processor.agent_call_timeout(processor, "q1") == nil
      assert {:ok, ^processor, []} = Processor.process(processor, answer)
    end

    test "an agent error settles the call as an error", %{v10: v10} do
      processor = Processor.new([v10])
      call = %{"@call" => "queryInventory"}

      {:ok, processor, _message} =
        Processor.call_agent_function(processor, "s", call, function_call_id: "q1")

      answer = %{
        "version" => "v1.0",
        "agentFunctionResponse" => %{
          "functionCallId" => "q1",
          "error" => %{"code" => "OUT_OF_STOCK", "message" => "none left"}
        }
      }

      assert {:ok, _processor, [{:rpc_settled, "q1", {:error, %Error{} = error}}]} =
               Processor.process(processor, answer)

      assert {error.category, error.code, error.function_call_id} == {:rpc, "OUT_OF_STOCK", "q1"}
      assert error.message =~ "none left"
    end

    test "timeouts, cancellation and disposal settle pending calls", %{v10: v10} do
      processor = Processor.new([v10], default_timeout_ms: 1_000)
      call = %{"@call" => "slow"}

      {:ok, processor, _} =
        Processor.call_agent_function(processor, "s", call, function_call_id: "a")

      {:ok, processor, _} =
        Processor.call_agent_function(processor, "s", call, function_call_id: "b")

      {:ok, processor, _} =
        Processor.call_agent_function(processor, "s", call, function_call_id: "c")

      assert Processor.agent_call_timeout(processor, "a") == 1_000

      assert {processor, [{:rpc_settled, "a", {:error, %Error{code: "TIMEOUT"}}}]} =
               Processor.timeout_agent_call(processor, "a")

      assert {processor, [{:rpc_settled, "b", {:error, %Error{code: "CANCELLED"}}}]} =
               Processor.cancel_agent_call(processor, "b")

      assert {processor, [{:rpc_settled, "c", {:error, %Error{code: "CANCELLED"}}}]} =
               Processor.dispose(processor)

      assert {:error, %Error{code: "DISPOSED"}} =
               Processor.call_agent_function(processor, "s", call)
    end

    test "apply_operation/2 takes decoded operations", %{v09: v09} do
      processor = ready(v09)
      operation = %UpdateDataModel{surface_id: "s", path: "/x", value: 3}

      assert {:ok, _processor, [{:data_model_updated, "s", "/x"}]} =
               Processor.apply_operation(processor, operation)
    end
  end

  describe "allowed message actions" do
    test "operations outside the list are rejected", %{v09: v09} do
      config = %{Config.strict() | allowed_messages: ["createSurface"]}
      processor = Processor.new([v09], validation: config)

      assert {:ok, processor, _} = Processor.process(processor, create(v09, "s"))

      {error, _} =
        failure(
          Processor.process(processor, %{
            "version" => "v0.9",
            "deleteSurface" => %{"surfaceId" => "s"}
          })
        )

      assert error.code == "INVALID_ACTION"

      assert error.message ==
               "Message action 'deleteSurface' is not allowed. Allowed actions: createSurface."
    end
  end

  describe "renderer_capabilities/2" do
    test "lists supported catalog ids per version", %{v09: v09, v10: v10} do
      processor = Processor.new([v09, v10])

      assert {:ok, capabilities} =
               Processor.renderer_capabilities(processor, versions: ["v0.9", "v1.0"])

      assert capabilities == %{
               "v0.9" => %{"supportedCatalogIds" => [v09.catalog_id, v10.catalog_id]},
               "v1.0" => %{"supportedCatalogIds" => [v09.catalog_id, v10.catalog_id]}
             }
    end

    test "requires a version", %{v09: v09} do
      processor = Processor.new([v09])

      for options <- [[], [versions: []], [versions: [nil, ""]]] do
        assert {:error, %Error{message: "At least one protocol version" <> _}} =
                 Processor.renderer_capabilities(processor, options)
      end
    end

    test "inline catalogs: legacy shape before v1.0", %{v09: v09} do
      processor = Processor.new([v09])

      assert {:ok, %{"v0.9" => %{"inlineCatalogs" => [inline]}}} =
               Processor.renderer_capabilities(processor,
                 versions: ["v0.9"],
                 include_inline_catalogs: true
               )

      assert inline["catalogId"] == v09.catalog_id

      assert %{"allOf" => [%{"$ref" => ref}, %{"properties" => properties}]} =
               inline["components"]["Text"]

      assert ref == "common_types.json#/$defs/ComponentCommon"
      assert properties["component"] == %{"const" => "Text"}
      refute Map.has_key?(properties, "id")
      assert is_list(inline["functions"])
      assert Enum.all?(inline["functions"], &Map.has_key?(&1, "returnType"))
    end

    test "inline catalogs: a custom envelope reference", %{v09: v09} do
      processor = Processor.new([v09])

      assert {:ok, %{"v0.9" => %{"inlineCatalogs" => [inline]}}} =
               Processor.renderer_capabilities(processor,
                 versions: ["v0.9"],
                 include_inline_catalogs: true,
                 component_envelope_ref: "urn:envelope"
               )

      assert %{"allOf" => [%{"$ref" => "urn:envelope"} | _]} = inline["components"]["Text"]
    end

    test "inline catalogs: the catalog schema from v1.0 on", %{v10: v10} do
      processor = Processor.new([v10])

      assert {:ok, %{"v1.0" => %{"inlineCatalogs" => [inline]}}} =
               Processor.renderer_capabilities(processor,
                 versions: ["v1.0"],
                 include_inline_catalogs: true
               )

      assert inline == A2UICore.Catalog.to_schema(v10)
    end
  end

  describe "renderer_data_model/2" do
    test "is nil when no surface asked for its data model", %{v09: v09} do
      assert {:ok, nil} = Processor.renderer_data_model(ready(v09))
    end

    test "collects the data of opted-in surfaces", %{v10: v10} do
      processor = Processor.new([v10])

      {:ok, processor, _} =
        Processor.process(processor, [
          create(v10, "a", %{"sendDataModel" => true, "dataModel" => %{"n" => 1}}),
          create(v10, "b", %{"dataModel" => %{"n" => 2}})
        ])

      assert {:ok, %{"version" => "v1.0", "surfaces" => surfaces}} =
               Processor.renderer_data_model(processor)

      assert surfaces == %{"a" => %{"n" => 1}}
    end

    test "filters by version", %{v10: v10} do
      processor = Processor.new([v10])

      {:ok, processor, _} =
        Processor.process(processor, create(v10, "a", %{"sendDataModel" => true}))

      assert {:ok, nil} = Processor.renderer_data_model(processor, "v0.9")
      assert {:ok, %{"version" => "v1.0"}} = Processor.renderer_data_model(processor, "v1.0")
    end

    test "surfaces on different versions need an explicit one", %{v09: v09, v10: v10} do
      processor = Processor.new([v09, v10])

      {:ok, processor, _} =
        Processor.process(processor, create(v09, "a", %{"sendDataModel" => true}))

      {:ok, processor, _} =
        Processor.process(processor, create(v10, "b", %{"sendDataModel" => true}))

      assert {:error, %Error{message: "Multiple protocol versions detected" <> _}} =
               Processor.renderer_data_model(processor)

      assert {:ok, %{"surfaces" => %{"b" => _}}} =
               Processor.renderer_data_model(processor, "v1.0")
    end
  end
end

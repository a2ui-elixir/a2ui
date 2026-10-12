defmodule A2UICore.MessageTest do
  @moduledoc false
  use ExUnit.Case, async: true

  import A2UICore.Message

  alias A2UICore.Error
  alias A2UICore.Message.Operation

  doctest A2UICore.Message

  describe "registry: adapter resolution" do
    test "version designators resolve by family" do
      for v <- ["v0.9", "0.9", "v0.9.0", "v0_9"] do
        assert {:ok, A2UICore.Message.Adapters.V0_9} =
                 A2UICore.Message.AdapterRegistry.get_adapter(v)
      end

      for v <- ["v0.9.1", "0.9.1"] do
        assert {:ok, A2UICore.Message.Adapters.V0_9} =
                 A2UICore.Message.AdapterRegistry.get_adapter(v)
      end

      for v <- ["v1.0", "1.0", "1.0.0", "v1_0"] do
        assert {:ok, A2UICore.Message.Adapters.V1_0} =
                 A2UICore.Message.AdapterRegistry.get_adapter(v)
      end
    end

    test "unsupported versions include v0.8 and unknown strings" do
      for v <- ["v0.8", "v99.0", "v1.0.0-beta", "hello"] do
        assert {:error, %Error{category: :validation}} =
                 A2UICore.Message.AdapterRegistry.get_adapter(v)
      end
    end

    test "known actions are the union across adapters plus legacy v0.8 keys" do
      assert A2UICore.Message.AdapterRegistry.all_known_actions() ==
               MapSet.new([
                 "createSurface",
                 "updateComponents",
                 "updateDataModel",
                 "deleteSurface",
                 "callRendererFunction",
                 "agentFunctionResponse",
                 # v0.8 legacy keys stay listed for the "not supported"
                 # error fidelity, without a v0.8 adapter.
                 "beginRendering",
                 "surfaceUpdate",
                 "dataModelUpdate"
               ])
    end
  end

  describe "registry: payload sniffing" do
    test "nil is a no-op" do
      assert {:ok, []} = decode(nil)
    end

    test "non-collection payloads are rejected with invalid_payload_type at messages.0.version" do
      for bad <- [42, "str", true] do
        assert {:error, %Error{details: [%{code: "invalid_payload_type", path: "messages.0.version"}]}} =
                 decode(bad)
      end
    end

    test "empty list is empty_payload" do
      assert {:error, %Error{details: [%{code: "empty_payload"}]}} = decode([])
    end

    test "messages wrapper recurses" do
      assert {:ok, [%Operation.UpdateDataModel{}]} =
               decode(%{
                 "messages" => [
                   %{
                     "version" => "v1.0",
                     "updateDataModel" => %{"surfaceId" => "main", "value" => 1}
                   }
                 ]
               })
    end

    test "list sniffs via its first item" do
      assert {:ok, ops} =
               decode([
                 %{"version" => "v1.0", "deleteSurface" => %{"surfaceId" => "a"}},
                 %{"version" => "v1.0", "deleteSurface" => %{"surfaceId" => "b"}}
               ])

      assert length(ops) == 2
    end

    test "missing version fails with missing_field at messages.0.version" do
      # Note: `deleteSurface` is a legacy v0.8 key, so a versionless
      # message using it routes to the unsupported-v0.8 error instead.
      assert {:error, %Error{details: [%{code: "missing_field", path: "messages.0.version"}]}} =
               decode(%{"bogusAction" => %{"surfaceId" => "a"}})
    end

    test "non-string version fails with type_mismatch" do
      assert {:error, %Error{details: [%{code: "type_mismatch", path: "messages.0.version"}]}} =
               decode(%{"version" => 1, "deleteSurface" => %{"surfaceId" => "a"}})
    end

    test "legacy v0.8 action keys report unsupported v0.8" do
      assert {:error, %Error{message: msg}} =
               decode(%{"beginRendering" => %{"surfaceId" => "a"}})

      assert msg =~ "Unsupported protocol version 'v0.8'"
    end
  end

  describe "adapter: action guards" do
    test "multiple action keys are rejected" do
      assert {:error, %Error{message: msg}} =
               decode(%{
                 "version" => "v1.0",
                 "deleteSurface" => %{"surfaceId" => "a"},
                 "createSurface" => %{"surfaceId" => "a"}
               })

      assert msg =~ "multiple conflicting update actions"
      assert msg =~ "createSurface, deleteSurface"
    end

    test "foreign-version action key gets the 'not supported' message" do
      assert {:error, %Error{message: msg}} =
               decode(%{"version" => "v1.0", "beginRendering" => %{}})

      assert msg =~ "action 'beginRendering' is not supported in protocol version v1.0"
    end

    test "no action key at all" do
      assert {:error, %Error{message: msg}} = decode(%{"version" => "v1.0", "bogus" => %{}})
      assert msg =~ "message must contain exactly one update action"
    end

    test "action payload must be an object" do
      assert {:error, %Error{message: msg}} =
               decode(%{"version" => "v1.0", "deleteSurface" => "not-a-map"})

      assert msg =~ "Payload for action 'deleteSurface' must be an object"
    end

    test "surfaceId must be a string when present" do
      assert {:error, %Error{message: msg}} =
               decode(%{"version" => "v1.0", "deleteSurface" => %{"surfaceId" => 5}})

      assert msg =~ "surfaceId must be a string"
    end

    test "version compatibility is enforced per message" do
      # "v1.0.0" passes the compatibility check (canonicalizes to "1.0")
      # but keeps its raw spelling through prepare, so the schema's
      # `const "v1.0"` rejects it — same as the reference's pydantic
      # literal ("Input should be 'v1.0'").
      assert {:error, %Error{message: msg}} =
               decode(%{"version" => "v1.0.0", "deleteSurface" => %{"surfaceId" => "a"}})

      assert msg =~ "'v1.0' was expected"
    end

    test "v0.9 family accepts v0.9.1 messages" do
      assert {:ok, [%Operation.DeleteSurface{}]} =
               decode(%{"version" => "v0.9.1", "deleteSurface" => %{"surfaceId" => "a"}})
    end
  end

  describe "decode: happy paths per action" do
    test "v1.0 updateDataModel with null value decodes as delete" do
      assert {:ok, [%Operation.UpdateDataModel{value: nil, path: "/x"}]} =
               decode(%{
                 "version" => "v1.0",
                 "updateDataModel" => %{"surfaceId" => "s", "path" => "/x", "value" => nil}
               })
    end

    test "v1.0 updateDataModel requires value" do
      assert {:error, %Error{category: :validation}} =
               decode(%{"version" => "v1.0", "updateDataModel" => %{"surfaceId" => "s"}})
    end

    test "v0.9 updateDataModel without value is a delete" do
      assert {:ok, [%Operation.UpdateDataModel{value: nil}]} =
               decode(%{"version" => "v0.9", "updateDataModel" => %{"surfaceId" => "s"}})
    end

    test "v1.0 createSurface with inline components expands to three ops" do
      assert {:ok, [create, update_components, update_data_model]} =
               decode(%{
                 "version" => "v1.0",
                 "createSurface" => %{
                   "surfaceId" => "s",
                   "catalogId" => "basic",
                   "sendDataModel" => true,
                   "components" => [%{"id" => "root", "component" => "Text", "text" => "Hi"}],
                   "dataModel" => %{"user" => "Ada"}
                 }
               })

      assert %Operation.CreateSurface{surface_id: "s", send_data_model: true} = create
      assert %Operation.UpdateComponents{components: [%{"id" => "root"} | _]} = update_components
      assert %Operation.UpdateDataModel{path: "/", value: %{"user" => "Ada"}} = update_data_model
    end

    test "v0.9 createSurface keeps theme; v1.0 drops it" do
      assert {:ok, [%Operation.CreateSurface{theme: %{"primaryColor" => "#112233"}}]} =
               decode(%{
                 "version" => "v0.9",
                 "createSurface" => %{
                   "surfaceId" => "s",
                   "catalogId" => "basic",
                   "theme" => %{"primaryColor" => "#112233"}
                 }
               })

      # `theme` is not part of the v1.0 createSurface schema at all.
      assert {:error, %Error{}} =
               decode(%{
                 "version" => "v1.0",
                 "createSurface" => %{"surfaceId" => "s", "theme" => %{}}
               })
    end

    test "v1.0 callRendererFunction requires catalogId in callFunction" do
      assert {:ok, [op]} =
               decode(%{
                 "version" => "v1.0",
                 "callRendererFunction" => %{
                   "functionCallId" => "fc1",
                   "callFunction" => %{
                     "@call" => "required",
                     "catalogId" => "https://a2ui.org/specification/v1_0/catalogs/basic/catalog.json",
                     "args" => %{"value" => "text"}
                   }
                 }
               })

      assert %Operation.CallRendererFunction{
               function_call_id: "fc1",
               call: "required",
               args: %{"value" => "text"}
             } = op

      # Missing `catalogId` in callFunction is a v1.0 schema error.
      assert {:error, %Error{}} =
               decode(%{
                 "version" => "v1.0",
                 "callRendererFunction" => %{
                   "functionCallId" => "fc1",
                   "callFunction" => %{"@call" => "required", "args" => %{"value" => "text"}}
                 }
               })
    end

    test "v1.0 agentFunctionResponse with error" do
      assert {:ok, [op]} =
               decode(%{
                 "version" => "v1.0",
                 "agentFunctionResponse" => %{
                   "functionCallId" => "fc1",
                   "error" => %{"code" => "NOT_FOUND", "message" => "nope"}
                 }
               })

      assert %Operation.AgentFunctionResponse{error: %{"code" => "NOT_FOUND"}} = op
    end

    test "v1.0 agentFunctionResponse requires exactly one of value/error" do
      assert {:error, %Error{}} =
               decode(%{
                 "version" => "v1.0",
                 "agentFunctionResponse" => %{"functionCallId" => "fc1"}
               })

      assert {:error, %Error{}} =
               decode(%{
                 "version" => "v1.0",
                 "agentFunctionResponse" => %{
                   "functionCallId" => "fc1",
                   "value" => 1,
                   "error" => %{"code" => "X", "message" => "y"}
                 }
               })
    end
  end

  describe "decode: schema validation details" do
    test "surfaceId type error is caught by the pre-check (reference behavior)" do
      # The reference's `_get_surface_id` pre-check rejects a non-string
      # surfaceId before schema validation — with no details.
      assert {:error, %Error{message: msg, details: []}} =
               decode(%{"version" => "v1.0", "createSurface" => %{"surfaceId" => 123}})

      assert msg =~ "surfaceId must be a string"
    end

    test "schema-level type errors carry path and code" do
      assert {:error, %Error{details: details, message: msg}} =
               decode(%{
                 "version" => "v1.0",
                 "createSurface" => %{"surfaceId" => "s", "sendDataModel" => "yes"}
               })

      assert Enum.any?(
               details,
               &(&1.path == "createSurface.sendDataModel" and &1.code == "type_mismatch")
             )

      assert msg =~ "Invalid v1.0 message"
    end

    test "missing version on a structurally valid action message" do
      # Without a version, the factory-level sniff fails before the
      # adapter's schema validation is reached.
      assert {:error, %Error{message: msg}} =
               decode(%{"createSurface" => %{"surfaceId" => "s"}})

      assert msg =~ "no version header or legacy v0.8 action found"
    end

    test "unknown component fails against the catalog (unevaluatedProperties path)" do
      assert {:error, %Error{details: details}} =
               decode(%{
                 "version" => "v1.0",
                 "updateComponents" => %{
                   "surfaceId" => "s",
                   "components" => [%{"id" => "root", "component" => "NotAComponent"}]
                 }
               })

      assert Enum.any?(details, &(&1.code in ["invalid_value", "type_mismatch"]))
    end

    test "valid Text component passes against the shipped catalog" do
      assert {:ok, [%Operation.UpdateComponents{}]} =
               decode(%{
                 "version" => "v1.0",
                 "updateComponents" => %{
                   "surfaceId" => "s",
                   "components" => [%{"id" => "root", "component" => "Text", "text" => "hi"}]
                 }
               })
    end

    test "extra key on a component is rejected via unevaluatedProperties" do
      assert {:error, %Error{details: details}} =
               decode(%{
                 "version" => "v1.0",
                 "updateComponents" => %{
                   "surfaceId" => "s",
                   "components" => [
                     %{"id" => "root", "component" => "Text", "text" => "hi", "bogus" => 1}
                   ]
                 }
               })

      assert Enum.any?(details, &(&1.code == "extra_field"))
    end
  end

  describe "encode: canonical operations to wire maps" do
    test "v1.0 updateDataModel always carries value" do
      op = %Operation.UpdateDataModel{surface_id: "s", path: "/x", value: nil}

      assert %{"updateDataModel" => %{"value" => nil, "path" => "/x"}} =
               encode(op, version: "v1.0")
    end

    test "v0.9 updateDataModel omits a nil value" do
      op = %Operation.UpdateDataModel{surface_id: "s", path: "/x", value: nil}

      refute Map.has_key?(encode(op)["updateDataModel"], "value")
    end

    test "v0.9 createSurface keeps theme, v1.0 does not" do
      op = %Operation.CreateSurface{surface_id: "s", theme: %{"primaryColor" => "#fff"}}

      assert Map.has_key?(encode(op, version: "v0.9")["createSurface"], "theme")
      refute Map.has_key?(encode(op, version: "v1.0")["createSurface"], "theme")
    end

    test "encoding re-validates: encode ∘ decode round-trips through the schema" do
      original = %{
        "version" => "v1.0",
        "updateDataModel" => %{"surfaceId" => "s", "path" => "/a/b", "value" => [1, 2]}
      }

      assert {:ok, [op]} = decode(original)
      encoded = encode(op, version: "v1.0")
      assert {:ok, _} = decode(encoded)
      assert encoded == original
    end
  end
end
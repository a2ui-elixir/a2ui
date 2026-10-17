defmodule A2UICore.EdgeCasesTest do
  @moduledoc false
  # Error paths and rarely-taken branches of the wire-format modules that
  # the fidelity corpus does not reach. Organized by module.

  use ExUnit.Case, async: true

  alias A2UICore.Error
  alias A2UICore.Error.Detail
  alias A2UICore.Message
  alias A2UICore.Message.{Adapter, AdapterRegistry, Operation}
  alias A2UICore.Message.Adapters.{V0_9, V1_0}
  alias A2UICore.Pointer
  alias A2UICore.Schema
  alias A2UICore.Schema.{ECMA262, Source}
  alias A2UICore.SemVer
  alias A2UICore.Validation.Integrity
  alias A2UICore.Version

  @basic_v1 "https://a2ui.org/specification/v1_0/catalogs/basic/catalog.json"

  describe "A2UICore" do
    test "lists the supported protocol versions" do
      assert A2UICore.supported_protocol_versions() == ["v0.9", "v0.9.1", "v1.0"]
    end
  end

  describe "Error" do
    test "new/4 carries every option and raise!/4 raises it" do
      error =
        Error.new(:state, "BOOM", "bad",
          path: "/a",
          surface_id: "s",
          function_call_id: "f",
          details: []
        )

      assert %Error{
               category: :state,
               code: "BOOM",
               path: "/a",
               surface_id: "s",
               function_call_id: "f"
             } = error

      raised =
        assert_raise Error, fn -> Error.raise!(:data, "X", "msg", path: "/p", surface_id: "s") end

      assert %Error{category: :data, code: "X", path: "/p", surface_id: "s"} = raised
      assert_raise Error, fn -> Error.raise!(:data, "X", "msg") end
    end

    test "Detail.new/3 defaults the path and from_map/1 reads atom or string keys" do
      assert %Detail{code: "c", message: "m", path: nil} = Detail.new("c", "m")

      assert %Detail{code: "c", message: "m", path: "p"} =
               Detail.from_map(%{code: "c", message: "m", path: "p"})

      assert %Detail{code: "c", message: "m", path: "p"} =
               Detail.from_map(%{"code" => "c", "message" => "m", "path" => "p"})
    end
  end

  describe "Message encode/decode helpers" do
    test "decode!/2 returns operations or raises the error" do
      assert [%Operation.DeleteSurface{surface_id: "a"}] =
               Message.decode!(%{"version" => "v1.0", "deleteSurface" => %{"surfaceId" => "a"}})

      assert_raise Error, fn -> Message.decode!(%{"version" => "v1.0", "bogus" => %{}}) end
      assert Message.decode!(nil) == []
    end

    test "encode/2 handles one op, a list, and an empty list" do
      op = %Operation.DeleteSurface{surface_id: "a"}

      assert %{"version" => "v1.0", "deleteSurface" => %{"surfaceId" => "a"}} =
               Message.encode(op, version: "v1.0")

      assert [%{"deleteSurface" => _}, %{"deleteSurface" => _}] = Message.encode([op, op])
      assert Message.encode([]) == []
    end

    test "Operation.action/1 names every operation" do
      assert Operation.action(%Operation.CreateSurface{surface_id: "s"}) == "createSurface"

      assert Operation.action(%Operation.UpdateComponents{surface_id: "s", components: []}) ==
               "updateComponents"

      assert Operation.action(%Operation.UpdateDataModel{surface_id: "s"}) == "updateDataModel"
      assert Operation.action(%Operation.DeleteSurface{surface_id: "s"}) == "deleteSurface"

      assert Operation.action(%Operation.CallRendererFunction{function_call_id: "c", call: "now"}) ==
               "callRendererFunction"

      assert Operation.action(%Operation.AgentFunctionResponse{function_call_id: "c"}) ==
               "agentFunctionResponse"
    end

    test "v1.0 RPC operations encode to the wire and decode back" do
      call = %Operation.CallRendererFunction{
        function_call_id: "c1",
        call: "openUrl",
        catalog_id: @basic_v1,
        args: %{"url" => "https://example.com"}
      }

      assert %{
               "version" => "v1.0",
               "callRendererFunction" => %{
                 "functionCallId" => "c1",
                 "callFunction" => %{
                   "@call" => "openUrl",
                   "catalogId" => @basic_v1,
                   "args" => %{"url" => _}
                 }
               }
             } = encoded = Message.encode(call)

      assert {:ok, [^call]} = Message.decode(encoded)

      no_args = %{call | args: %{}}
      refute Map.has_key?(Message.encode(no_args)["callRendererFunction"]["callFunction"], "args")

      ok = %Operation.AgentFunctionResponse{function_call_id: "c1", value: 3}

      assert %{"agentFunctionResponse" => %{"functionCallId" => "c1", "value" => 3}} =
               encoded_ok = Message.encode(ok)

      assert {:ok, [^ok]} = Message.decode(encoded_ok)

      failed = %Operation.AgentFunctionResponse{
        function_call_id: "c1",
        error: %{"code" => "E", "message" => "failed"}
      }

      assert %{"agentFunctionResponse" => %{"error" => %{"code" => "E", "message" => "failed"}}} =
               encoded_failed = Message.encode(failed)

      refute Map.has_key?(encoded_failed["agentFunctionResponse"], "value")
      assert {:ok, [^failed]} = Message.decode(encoded_failed)
    end

    test "v1.0 updateDataModel always carries value; v0.9 omits a nil value" do
      op = %Operation.UpdateDataModel{surface_id: "s", path: "/a", value: nil}
      assert %{"updateDataModel" => %{"value" => nil}} = Message.encode(op, version: "v1.0")
      refute Map.has_key?(Message.encode(op, version: "v0.9")["updateDataModel"], "value")
    end
  end

  describe "Adapter.extract" do
    test "nil, empty list and scalars are no-ops" do
      assert {:ok, []} = Adapter.extract(V1_0, nil)
      assert {:ok, []} = Adapter.extract(V1_0, [])
      assert {:ok, []} = Adapter.extract(V1_0, 42)
    end

    test "a message whose version the adapter does not accept is a VERSION_MISMATCH" do
      delete = %{"deleteSurface" => %{"surfaceId" => "a"}}

      assert {:error, %Error{code: "VERSION_MISMATCH", message: m}} =
               Adapter.extract(V1_0, Map.put(delete, "version", "v0.9"))

      assert m =~ "Input should be 'v1.0'"

      assert {:error, %Error{code: "VERSION_MISMATCH", message: m}} =
               Adapter.extract(V0_9, Map.put(delete, "version", "v1.0"))

      assert m =~ ~s(one of ["v0.9", "v0.9.1"])

      assert {:error, %Error{code: "VERSION_MISMATCH"}} =
               Adapter.extract(V1_0, Map.put(delete, "version", 5))

      assert {:error, %Error{code: "VERSION_MISMATCH", message: m}} =
               Adapter.extract(V1_0, delete)

      assert m =~ "required property"
    end

    test "an error in a later list item stops extraction" do
      ok = %{"version" => "v1.0", "deleteSurface" => %{"surfaceId" => "a"}}
      bad = %{"version" => "v1.0", "deleteSurface" => %{"surfaceId" => 1}}
      assert {:error, %Error{code: "INVALID_SURFACE_ID"}} = Adapter.extract(V1_0, [ok, bad])
    end

    test "message_def/2 is nil for an unknown action or an envelope without defs" do
      assert Adapter.message_def(%{}, "createSurface") == nil
      assert Adapter.message_def(%{"$defs" => %{}}, "nope") == nil
    end
  end

  describe "AdapterRegistry" do
    test "unsupported versions are rejected, supported ones normalized" do
      assert {:error, %Error{code: "UNSUPPORTED_VERSION", message: m}} =
               AdapterRegistry.get_adapter("v0.8")

      assert m =~ "v0.8"
      assert {:error, %Error{code: "UNSUPPORTED_VERSION"}} = AdapterRegistry.get_adapter("v99.0")

      assert {:error, %Error{code: "UNSUPPORTED_VERSION"}} =
               AdapterRegistry.get_adapter("not a version")

      assert {:ok, V0_9} = AdapterRegistry.get_adapter("0.9")
      assert {:ok, V1_0} = AdapterRegistry.get_adapter("1.0")
    end

    test "payload sniffing reports the offending type with a messages.N.version path" do
      for {payload, type} <- [
            {42, "integer"},
            {1.5, "float"},
            {true, "boolean"},
            {"s", "string"},
            {nil, "null"}
          ] do
        assert {:error,
                %Error{
                  details: [
                    %{code: "invalid_payload_type", path: "messages.0.version", message: m}
                  ]
                }} =
                 AdapterRegistry.resolve_from_payload(payload)

        assert m =~ type
      end

      assert {:error, %Error{details: [%{code: "empty_payload"}]}} =
               AdapterRegistry.resolve_from_payload([])

      assert {:error, %Error{details: [%{code: "invalid_payload_type"}]}} =
               AdapterRegistry.resolve_from_payload([42])

      for {version, type} <- [{[1], "list"}, {%{}, "map"}, {:atom, "term"}, {5, "integer"}] do
        assert {:error, %Error{details: [%{code: "type_mismatch", message: m}]}} =
                 AdapterRegistry.resolve_from_payload(%{"version" => version})

        assert m =~ type
      end
    end

    test "legacy v0.8 action keys report an unsupported version" do
      assert {:error, %Error{code: "UNSUPPORTED_VERSION"}} =
               AdapterRegistry.resolve_from_payload(%{"beginRendering" => %{}})
    end

    test "all_known_actions includes the legacy keys" do
      assert MapSet.member?(AdapterRegistry.all_known_actions(), "beginRendering")
      assert MapSet.member?(AdapterRegistry.all_known_actions(), "createSurface")
    end
  end

  describe "Integrity" do
    test "limits are exposed" do
      assert Integrity.max_global_depth() == 50
      assert Integrity.max_func_call_depth() == 5
    end

    test "global nesting beyond the limit is a recursion error" do
      deep = Enum.reduce(1..60, [], fn _, acc -> [acc] end)

      assert {:error, %Error{category: :recursion, message: m}} =
               Integrity.validate_recursion_and_paths(deep)

      assert m =~ "Global recursion limit"
      assert_raise Error, fn -> Integrity.validate_recursion_and_paths!(deep) end
    end

    test "function-call nesting beyond the limit is a recursion error (v0.9+ and v0.8 shapes)" do
      nested =
        Enum.reduce(1..6, %{"call" => "x", "args" => %{}}, fn _, acc ->
          %{"call" => "f", "args" => %{"a" => acc}}
        end)

      assert {:error, %Error{category: :recursion, message: m}} =
               Integrity.validate_recursion_and_paths(nested)

      assert m =~ "functionCall depth"

      legacy = Enum.reduce(1..6, %{"x" => 1}, fn _, acc -> %{"functionCall" => acc} end)

      assert {:error, %Error{category: :recursion}} =
               Integrity.validate_recursion_and_paths(legacy)

      shallow =
        Enum.reduce(1..3, %{"call" => "x", "args" => %{}}, fn _, acc ->
          %{"call" => "f", "args" => %{"a" => acc}}
        end)

      assert :ok = Integrity.validate_recursion_and_paths(shallow)
    end

    test "invalid pointer syntax is rejected for path and @path" do
      for key <- ["path", "@path"] do
        assert {:error, %Error{code: "invalid_pointer", details: [%{path: ^key}]}} =
                 Integrity.validate_recursion_and_paths(%{key => "/a~2b"})
      end

      assert :ok =
               Integrity.validate_recursion_and_paths(%{"path" => "/a/b~0~1", "@path" => "rel/x"})
    end
  end

  describe "Pointer" do
    test "constants and the client-scope join" do
      assert Pointer.max_array_index() == 10_000
      assert "__proto__" in Pointer.forbidden_segments()
      assert Pointer.resolve("/abs", "/ctx") == "/abs"
      assert Pointer.resolve("rel", nil) == "/rel"
      assert Pointer.resolve("name", "/user") == "/user/name"
      assert Pointer.resolve("name", "/") == "/name"
    end
  end

  describe "SemVer and Version" do
    test "String.Chars drops a zero patch only without prerelease or build" do
      {:ok, v} = SemVer.parse("1.0.0")
      assert to_string(v) == "1.0"
      {:ok, v} = SemVer.parse("1.2.3-rc.1+b5")
      assert to_string(v) =~ "1.2.3"
    end

    test "equal prerelease lists compare equal" do
      assert SemVer.compare("1.0.0-alpha.1", "1.0.0-alpha.1") == 0
      assert SemVer.compare("1.0.0", "1.0.0") == 0
    end

    test "catalog compatibility handles nils, map shapes and non-semver strings" do
      refute Version.catalog_compatible?(nil, "v1.0")
      refute Version.catalog_compatible?("v1.0", nil)
      assert Version.catalog_compatible?("0.9.1", "0.9", %{"0.9" => ["0.9.1"]})
      assert Version.catalog_compatible?("0.9.1", "0.9", %{"0.9" => "0.9.1"})
      refute Version.catalog_compatible?("0.9.1", "0.9", %{})
      assert Version.catalog_compatible?("custom", "custom")
      refute Version.catalog_compatible?("custom", "other")
      refute Version.catalog_compatible?(1, "v1.0")
    end

    test "to_protocol_version rejects garbage" do
      assert :error = Version.to_protocol_version("garbage")
      assert {:ok, "v1.0"} = Version.to_protocol_version("1.0.0-beta")
    end
  end

  describe "Schema.Source" do
    test "every logical document resolves for every supported version" do
      for version <- ["v0.9", "v0.9.1", "v1.0"],
          name <- [
            :agent_to_renderer,
            :renderer_to_agent,
            :common_types,
            :capabilities,
            :renderer_capabilities,
            :data_model,
            :list,
            :wrapper
          ] do
        assert is_map(Source.document(version, name)), "#{version} #{name}"
      end

      assert Source.document("v0.9", :catalog_definition) == nil
      assert is_map(Source.document("v1.0", :catalog_definition))
      assert is_map(Source.document("v1.0", "sample.json"))
      assert Source.document("v1.0", :no_such_document) == nil
    end

    test "catalogs and argument errors" do
      assert is_map(Source.catalog("v0.9", :basic))
      assert is_map(Source.catalog("v0.9.1", :basic))
      assert is_map(Source.catalog("v1.0", :testing))
      assert_raise ArgumentError, ~r/only for v1.0/, fn -> Source.catalog("v0.9", :testing) end

      assert_raise ArgumentError, ~r/no catalog for protocol version/, fn ->
        Source.catalog("v2.0", :basic)
      end

      assert_raise ArgumentError, ~r/unknown protocol version/, fn ->
        Source.document("v2.0", :common_types)
      end
    end
  end

  describe "Schema $ref resolution failures" do
    defp ref_error(schema, data \\ 1) do
      assert {:error, [%{code: "invalid_reference", message: message}]} =
               Schema.validate(data, schema)

      message
    end

    test "unresolvable pointer, document and anchor" do
      assert ref_error(%{"$ref" => "#/$defs/nope"}) =~ "not found"
      assert ref_error(%{"$ref" => "missing.json"}) =~ "no such document"
      assert ref_error(%{"$ref" => "#anchor"}) =~ "no anchor 'anchor'"
    end

    test "a self-referential $ref hits the recursion limit" do
      assert ref_error(%{"$ref" => "#"}) =~ "recursion limit"
    end

    test "pointers descend through arrays" do
      schema = %{"$defs" => %{"a" => [%{"type" => "string"}]}, "$ref" => "#/$defs/a/0"}
      assert :ok = Schema.validate("x", schema)
      assert {:error, [%{code: "type_mismatch"}]} = Schema.validate(1, schema)

      assert ref_error(%{"$defs" => %{"a" => [%{}]}, "$ref" => "#/$defs/a/1"}) =~ "not found"
      assert ref_error(%{"$defs" => %{"a" => [%{}]}, "$ref" => "#/$defs/a/x"}) =~ "not found"
      assert ref_error(%{"$defs" => %{"a" => true}, "$ref" => "#/$defs/a/b"}) =~ "not found"
    end
  end

  describe "ECMA262" do
    test "a leading ] in a class is a literal member (reference/PCRE rule)" do
      assert ECMA262.match?("[]a]", "]")
      assert ECMA262.match?("[]a]", "a")
      refute ECMA262.match?("[^]a]", "]")
      assert ECMA262.match?("[^]a]", "b")
    end

    test "invalid patterns are reported, not raised" do
      assert {:error, %Error{}} = ECMA262.search("[", "x")
      refute ECMA262.match?("[", "x")
      assert ECMA262.match?("^a$", "a")
    end

    test "a search stops after a million backtracking steps" do
      value = String.duplicate("a", 30) <> "!"

      assert {:error, %Error{code: "REGEX_LIMIT", message: message}} =
               ECMA262.search("^(a+)+$", value)

      assert message =~ "took too many steps"
      assert ECMA262.search("^a+$", value) == {:ok, false}
      assert ECMA262.search("^(a+)+!$", value) == {:ok, true}
    end

    test "compile!/1 raises on an invalid pattern" do
      assert %Regex{} = ECMA262.compile!("^a$")
      assert_raise Error, ~r/Cannot compile/, fn -> ECMA262.compile!("[") end
    end
  end

  describe "Schema engine edge cases" do
    test "a non-map, non-boolean schema is a programming error" do
      assert_raise ArgumentError, ~r/Invalid schema/, fn -> Schema.validate(1, "string") end
    end

    test "unknown types and multipleOf 0 never match" do
      assert {:error, [_]} = Schema.validate(1, %{"type" => "weird"})
      assert {:error, [_]} = Schema.validate(3, %{"multipleOf" => 0})
    end

    test "invalid regexes in pattern and patternProperties surface as errors" do
      assert {:error, [%{code: "invalid_value"}]} = Schema.validate("a", %{"pattern" => "["})

      assert {:error, [_ | _]} =
               Schema.validate(%{"a" => 1}, %{"patternProperties" => %{"[" => %{}}})
    end

    test "unevaluatedProperties accepts true and a schema" do
      assert :ok = Schema.validate(%{"a" => 1}, %{"unevaluatedProperties" => true})

      schema = %{
        "properties" => %{"a" => true},
        "unevaluatedProperties" => %{"type" => "integer"}
      }

      assert :ok = Schema.validate(%{"a" => 1, "b" => 2}, schema)
      assert {:error, [_ | _]} = Schema.validate(%{"a" => 1, "b" => "x"}, schema)
      assert :ok = Schema.validate("not an object", %{"unevaluatedProperties" => false})
    end

    test "`if` without then/else passes and a failing `if` without else passes" do
      assert :ok = Schema.validate("s", %{"if" => %{"type" => "string"}})

      assert :ok =
               Schema.validate(1, %{"if" => %{"type" => "string"}, "then" => %{"minLength" => 3}})
    end

    test "discriminated oneOf reports the selected branch's own errors" do
      schema = %{
        "discriminator" => %{"propertyName" => "k"},
        "oneOf" => [
          %{"type" => "object"},
          %{"properties" => %{"k" => %{"enum" => ["a"]}, "n" => %{"type" => "integer"}}},
          %{"properties" => %{"k" => %{"const" => "b"}}}
        ]
      }

      assert {:error, errors} =
               Schema.validate(%{"k" => "a", "n" => "x"}, %{
                 schema
                 | "oneOf" => tl(schema["oneOf"])
               })

      assert Enum.any?(errors, &(&1.path == "n"))

      assert {:error, [_ | _]} =
               Schema.validate(%{"k" => "zzz", "n" => "x"}, %{
                 schema
                 | "oneOf" => tl(schema["oneOf"])
               })
    end
  end

  describe "Schema format edge cases" do
    test "malformed time and offset shapes" do
      for {value, ok?} <- [
            {"garbage", false},
            {"12:30:00+05", true},
            {"12:30:00+05:30", true},
            {"12:30:00z", true}
          ] do
        result = Schema.validate(value, %{"format" => "time"}, formats: :assert)
        assert result == :ok == ok?, "#{value}: #{inspect(result)}"
      end
    end
  end
end

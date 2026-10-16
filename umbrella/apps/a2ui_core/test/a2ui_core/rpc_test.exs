defmodule A2UICore.RPCTest do
  @moduledoc false
  use ExUnit.Case, async: true

  alias A2UICore.{Catalog, Error, RPC}
  alias A2UICore.Message.Operation.{AgentFunctionResponse, CallRendererFunction}
  alias A2UICore.Resolution.DataContext
  alias A2UICore.State.DataModel

  @catalog_id "https://example.test/catalogs/tools"

  defp declaration(name, extra) do
    Map.merge(
      %{
        "type" => "object",
        "properties" => %{"@call" => %{"const" => name}, "args" => %{"type" => "object"}},
        "required" => ["@call"]
      },
      extra
    )
  end

  defp catalog(version \\ "v1.0") do
    amount = %{
      "type" => "object",
      "properties" => %{"amount" => %{"type" => "number"}},
      "required" => ["amount"]
    }

    functions = %{
      "echo" => declaration("echo", %{"allowedCallers" => "rendererOrAgent"}),
      "double" =>
        "double"
        |> declaration(%{"allowedCallers" => "agentOnly"})
        |> put_in(["properties", "args"], amount),
      "private" => declaration("private", %{"allowedCallers" => "rendererOnly"}),
      "unmarked" => declaration("unmarked", %{}),
      "unlock" =>
        declaration("unlock", %{
          "allowedCallers" => "rendererOrAgent",
          "requiresUserActivation" => true
        }),
      "raises" => declaration("raises", %{"allowedCallers" => "agentOnly"}),
      "fails" => declaration("fails", %{"allowedCallers" => "agentOnly"}),
      "withEffects" => declaration("withEffects", %{"allowedCallers" => "agentOnly"}),
      "stub" => declaration("stub", %{"allowedCallers" => "agentOnly"}),
      "wantsContext" => declaration("wantsContext", %{"allowedCallers" => "agentOnly"})
    }

    document = %{"catalogId" => @catalog_id, "components" => %{}, "functions" => functions}

    document
    |> Catalog.from_json!(protocol_version: version)
    |> Catalog.put_implementations(%{
      "echo" => fn args, _context -> {:ok, args} end,
      "double" => fn %{"amount" => amount}, _context -> {:ok, amount * 2} end,
      "private" => fn _args, _context -> {:ok, "secret"} end,
      "unmarked" => fn _args, _context -> {:ok, "unmarked"} end,
      "unlock" => fn _args, _context -> {:ok, "unlocked"} end,
      "raises" => fn _args, _context -> raise "boom" end,
      "fails" => fn _args, _context ->
        {:error, Error.new(:expression, "EXECUTION_ERROR", "it failed")}
      end,
      "withEffects" => fn _args, _context -> {:ok, 7, [{:warning, %{code: "NOTE"}}]} end,
      "wantsContext" => fn _args, context -> {:ok, context} end
    })
  end

  defp rpc(options \\ []), do: RPC.new([catalog()], options)

  defp call(name, args \\ %{}, fields \\ []) do
    struct!(
      CallRendererFunction,
      Keyword.merge(
        [function_call_id: "c1", call: name, catalog_id: @catalog_id, args: args],
        fields
      )
    )
  end

  defp outcome(response) do
    assert %{"version" => _version, "rendererFunctionResponse" => body} = response
    body
  end

  describe "new/2" do
    test "needs a catalog" do
      assert_raise ArgumentError, ~r/At least one catalog/, fn -> RPC.new([]) end
    end

    test "starts with nothing pending" do
      rpc = rpc()

      assert RPC.pending(rpc) == []
      refute RPC.disposed?(rpc)
      assert RPC.pending_timeout(rpc, "x") == nil
    end
  end

  describe "call_renderer_function/3" do
    test "runs the function and answers with its value" do
      response = RPC.call_renderer_function(rpc(), call("echo", %{"a" => 1}))

      assert %{"version" => "v1.0"} = response
      assert %{"functionCallId" => "c1", "value" => %{"a" => 1}} = outcome(response)
    end

    test "a void result is a value of null" do
      catalog = Catalog.put_implementations(catalog(), %{"echo" => fn _a, _c -> {:ok, nil} end})
      response = RPC.call_renderer_function(RPC.new([catalog]), call("echo"))

      assert %{"rendererFunctionResponse" => %{"value" => nil} = body} = response
      assert Map.has_key?(body, "value")
    end

    test "the response carries the message's version" do
      catalog = catalog("v0.9")

      response =
        RPC.call_renderer_function(RPC.new([catalog]), call("echo", %{}, version: "v0.9"))

      assert %{"version" => "v0.9", "rendererFunctionResponse" => %{"value" => %{}}} = response
    end

    test "a call must name its catalog" do
      call = call("echo", %{"a" => 1}, catalog_id: nil)

      assert %{"error" => %{"code" => "INVALID_FUNCTION_CALL", "message" => message}} =
               outcome(RPC.call_renderer_function(rpc(), call))

      assert message == "No catalog available for function resolution."
    end

    test "a call that names a surface needs that surface's context" do
      call = call("echo", %{}, surface_id: "s1")

      assert %{
               "error" => %{
                 "code" => "INVALID_FUNCTION_CALL",
                 "message" => "Surface not found: s1"
               }
             } =
               outcome(RPC.call_renderer_function(rpc(), call))

      other = DataContext.new("/", surface_id: "s2")

      assert %{"error" => %{"message" => "Surface not found: s1"}} =
               outcome(RPC.call_renderer_function(rpc(), call, context: other))

      context =
        DataContext.new("/",
          surface_id: "s1",
          protocol_version: "v1.0",
          data_model: DataModel.new(%{"n" => 2})
        )

      call = call("echo", %{"n" => %{"@path" => "/n"}}, surface_id: "s1")

      assert %{"value" => %{"n" => 2}} =
               outcome(RPC.call_renderer_function(rpc(), call, context: context))
    end

    test "without a surface the arguments see an empty data model" do
      call = call("echo", %{"n" => %{"@path" => "/n"}, "k" => 1})

      assert %{"value" => %{"n" => nil, "k" => 1}} =
               outcome(RPC.call_renderer_function(rpc(), call))

      assert %{"value" => %DataContext{} = context} =
               outcome(RPC.call_renderer_function(rpc(), call("wantsContext")))

      assert context.surface_id == "_rpc_fallback_c1"
      assert context.catalog.catalog_id == @catalog_id
      assert Map.keys(context.catalogs) == [@catalog_id]
    end

    test "resolved arguments are validated; a failing expression is EXECUTION_ERROR" do
      call = call("double", %{"amount" => %{"@path" => "/missing"}})

      assert %{"error" => %{"code" => "INVALID_FUNCTION_CALL", "message" => message}} =
               outcome(RPC.call_renderer_function(rpc(), call))

      assert message =~ "Invalid arguments for function 'double'"

      call = call("echo", %{"x" => %{"@call" => "nope", "args" => %{}}})

      assert %{"error" => %{"code" => "EXECUTION_ERROR", "message" => message}} =
               outcome(RPC.call_renderer_function(rpc(), call))

      assert message =~ "nope"
    end

    test "an unknown catalog or function is INVALID_FUNCTION_CALL" do
      response = RPC.call_renderer_function(rpc(), call("echo", %{}, catalog_id: "elsewhere"))

      assert %{
               "error" => %{
                 "code" => "INVALID_FUNCTION_CALL",
                 "message" => "Catalog not found: elsewhere"
               }
             } =
               outcome(response)

      response = RPC.call_renderer_function(rpc(), call("ghost"))

      assert %{
               "error" => %{
                 "code" => "INVALID_FUNCTION_CALL",
                 "message" => "Function not found: ghost"
               }
             } =
               outcome(response)
    end

    test "a catalog of another protocol version is refused" do
      rpc = RPC.new([catalog("v0.9")])
      response = RPC.call_renderer_function(rpc, call("echo"))

      assert %{"error" => %{"code" => "INVALID_FUNCTION_CALL", "message" => message}} =
               outcome(response)

      assert message =~
               "Catalog specification version (v0.9) does not match message protocol version (v1.0)"
    end

    test "only agentOnly and rendererOrAgent functions can be called by the agent" do
      assert %{"value" => %{}} = outcome(RPC.call_renderer_function(rpc(), call("echo")))

      for name <- ["private", "unmarked"] do
        assert %{"error" => %{"code" => "INVALID_FUNCTION_CALL", "message" => message}} =
                 outcome(RPC.call_renderer_function(rpc(), call(name)))

        assert message ==
                 "Function '#{name}' cannot be called by agent (allowedCallers is rendererOnly)."
      end

      assert %{"value" => 14} =
               outcome(RPC.call_renderer_function(rpc(), call("double", %{"amount" => 7})))
    end

    test "functions that require user activation need it" do
      assert %{"error" => %{"code" => "INVALID_FUNCTION_CALL", "message" => message}} =
               outcome(RPC.call_renderer_function(rpc(), call("unlock")))

      assert message == "Function 'unlock' requires user activation context to execute."

      assert %{"value" => "unlocked"} =
               outcome(RPC.call_renderer_function(rpc(), call("unlock"), user_activated: true))
    end

    test "arguments are validated against the declaration" do
      response = RPC.call_renderer_function(rpc(), call("double", %{"amount" => "lots"}))

      assert %{"error" => %{"code" => "INVALID_FUNCTION_CALL", "message" => message}} =
               outcome(response)

      assert message =~ "Invalid arguments for function 'double'"
    end

    test "a failing function is EXECUTION_ERROR" do
      assert %{"error" => %{"code" => "EXECUTION_ERROR", "message" => "boom"}} =
               outcome(RPC.call_renderer_function(rpc(), call("raises")))

      assert %{"error" => %{"code" => "EXECUTION_ERROR", "message" => "it failed"}} =
               outcome(RPC.call_renderer_function(rpc(), call("fails")))
    end

    test "a function with effects answers with its value" do
      assert %{"value" => 7} = outcome(RPC.call_renderer_function(rpc(), call("withEffects")))
    end

    test "a declared function without an implementation is not callable" do
      assert %{"error" => %{"code" => "EXECUTION_ERROR", "message" => message}} =
               outcome(RPC.call_renderer_function(rpc(), call("stub")))

      assert message =~ "not callable"
    end

    test "the function receives the context of the surface the call names" do
      context = DataContext.new("/", surface_id: "s1")

      assert %{"value" => ^context} =
               outcome(
                 RPC.call_renderer_function(
                   rpc(),
                   call("wantsContext", %{}, surface_id: "s1"),
                   context: context
                 )
               )
    end

    test "a disposed handler answers DISPOSED" do
      {rpc, []} = RPC.dispose(rpc())

      assert %{"error" => %{"code" => "DISPOSED", "message" => "RpcHandler has been disposed."}} =
               outcome(RPC.call_renderer_function(rpc, call("echo")))
    end
  end

  describe "call_agent_function/4" do
    test "registers the call and returns the message" do
      call = %{"@call" => "queryInventory", "catalogId" => "store", "args" => %{"sku" => "A"}}

      assert {:ok, rpc, message} =
               RPC.call_agent_function(rpc(), "main", call,
                 function_call_id: "q1",
                 timeout_ms: 250
               )

      assert message == %{
               "version" => "v1.0",
               "callAgentFunction" => %{
                 "surfaceId" => "main",
                 "functionCallId" => "q1",
                 "callFunction" => call
               }
             }

      assert RPC.pending(rpc) == ["q1"]
      assert RPC.pending_timeout(rpc, "q1") == 250
    end

    test "ids are generated from a counter, the timeout defaults, zero means none" do
      call = %{"call" => "ping"}
      rpc = rpc(default_timeout_ms: 5_000)

      assert {:ok, rpc, first} = RPC.call_agent_function(rpc, "s", call)
      assert {:ok, rpc, second} = RPC.call_agent_function(rpc, "s", call, timeout_ms: 0)

      assert %{"callAgentFunction" => %{"functionCallId" => "call-1", "callFunction" => wire}} =
               first

      assert wire == %{"@call" => "ping"}
      assert %{"callAgentFunction" => %{"functionCallId" => "call-2"}} = second
      assert RPC.pending_timeout(rpc, "call-1") == 5_000
      assert RPC.pending_timeout(rpc, "call-2") == nil
      assert RPC.pending(rpc) == ["call-1", "call-2"]
    end

    test "a call needs a name" do
      for call <- [%{}, %{"@call" => ""}, %{"call" => 3}] do
        assert {:error, %Error{category: :rpc, code: "INVALID_FUNCTION_CALL"}} =
                 RPC.call_agent_function(rpc(), "s", call)
      end
    end

    test "a pending id cannot be reused" do
      call = %{"@call" => "ping"}
      {:ok, rpc, _message} = RPC.call_agent_function(rpc(), "s", call, function_call_id: "x")

      assert {:error, %Error{code: "DUPLICATE", function_call_id: "x"}} =
               RPC.call_agent_function(rpc, "s", call, function_call_id: "x")
    end

    test "a disposed handler refuses calls" do
      {rpc, []} = RPC.dispose(rpc())

      assert {:error, %Error{code: "DISPOSED"}} =
               RPC.call_agent_function(rpc, "s", %{"@call" => "ping"})
    end
  end

  describe "settling calls" do
    defp pending_rpc do
      call = %{"@call" => "ping"}

      {:ok, rpc, _} =
        RPC.call_agent_function(rpc(), "s", call, function_call_id: "a", timeout_ms: 40)

      {:ok, rpc, _} = RPC.call_agent_function(rpc, "s", call, function_call_id: "b")
      rpc
    end

    test "a response resolves its call with the value" do
      response = %AgentFunctionResponse{function_call_id: "a", value: %{"ok" => true}}

      assert {rpc, [{:resolved, "a", %{"ok" => true}}]} =
               RPC.handle_agent_function_response(pending_rpc(), response)

      assert RPC.pending(rpc) == ["b"]
    end

    test "an error response rejects with the agent's code and message" do
      response = %AgentFunctionResponse{
        function_call_id: "a",
        error: %{"code" => "NOT_FOUND", "message" => "no such sku"}
      }

      assert {_rpc, [{:rejected, "a", %Error{} = error}]} =
               RPC.handle_agent_function_response(pending_rpc(), response)

      assert {error.category, error.code, error.function_call_id} == {:rpc, "NOT_FOUND", "a"}
      assert error.message == "Agent function error [NOT_FOUND]: no such sku"
    end

    test "an error without a code or message gets defaults" do
      response = %AgentFunctionResponse{function_call_id: "a", error: %{}}

      assert {_rpc, [{:rejected, "a", %Error{code: "UNKNOWN_ERROR", message: message}}]} =
               RPC.handle_agent_function_response(pending_rpc(), response)

      assert message == "Agent function error [UNKNOWN_ERROR]: Agent function execution failed"
    end

    test "a response to a call that is not pending is ignored" do
      rpc = pending_rpc()
      response = %AgentFunctionResponse{function_call_id: "zzz", value: 1}

      assert {^rpc, []} = RPC.handle_agent_function_response(rpc, response)
    end

    test "a timeout rejects with TIMEOUT, once" do
      assert {rpc, [{:rejected, "a", %Error{code: "TIMEOUT", message: message}}]} =
               RPC.timeout(pending_rpc(), "a")

      assert message == "Agent function call 'ping' timed out after 40ms."
      assert RPC.pending(rpc) == ["b"]
      assert {^rpc, []} = RPC.timeout(rpc, "a")
    end

    test "cancelling rejects with CANCELLED" do
      assert {rpc, [{:rejected, "b", %Error{code: "CANCELLED", message: "gave up"}}]} =
               RPC.cancel(pending_rpc(), "b", "gave up")

      assert {^rpc, []} = RPC.cancel(rpc, "b")

      assert {_rpc,
              [{:rejected, "a", %Error{code: "CANCELLED", message: "The call was cancelled."}}]} =
               RPC.cancel(pending_rpc(), "a")
    end

    test "disposal rejects every pending call and is idempotent" do
      assert {rpc, settlements} = RPC.dispose(pending_rpc(), "shutting down")

      assert [{:rejected, "a", a}, {:rejected, "b", b}] = settlements
      assert a.code == "CANCELLED"
      assert a.message == "RpcHandler disposed while call 'a' was pending: shutting down"
      assert b.function_call_id == "b"

      assert RPC.disposed?(rpc)
      assert RPC.pending(rpc) == []
      assert {^rpc, []} = RPC.dispose(rpc)
    end
  end
end

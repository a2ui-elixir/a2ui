defmodule A2UIConformance.Handlers.HandleRpc do
  @moduledoc false

  # `handle_rpc` (reference harness L1373-1578). The case declares the
  # functions of a catalog (`functionMetadata`) and one or two exchanges:
  #
  #   * `message` — an agent message handled by the processor: either it
  #     fails with `expect.error`, or it produces `expect.response`
  #     (`null` for "no response"), compared on version, call id, value or
  #     error code, and a substring of the error message;
  #   * `outboundCall` — a renderer call to an agent function: answered by
  #     `inboundResponse` (the settled result is `expect.result`), left
  #     pending twice (`secondOutboundCall`: `DUPLICATE`), or left to
  #     expire (`timeoutMs`: `TIMEOUT`).
  #
  # The functions the reference harness implements by name are
  # reproduced here; the timer of a call is the host's, so the handler
  # plays the host and reports the expiry itself.

  @behaviour A2UIConformance.Handler

  import ExUnit.Assertions

  alias A2UIConformance.{Case, Matchers}
  alias A2UICore.{Catalog, Error, Processor}

  @basic_v1 "https://a2ui.org/specification/v1_0/catalogs/basic/catalog.json"

  @impl true
  def run(%Case{raw: raw}, _context) do
    args = raw["args"] || %{}
    processor = Processor.new([build_catalog(raw, args)])

    if is_map(args["message"]), do: check_message(processor, raw, args)

    cond do
      is_map(args["outboundCall"]) and is_map(args["inboundResponse"]) ->
        check_answered_call(processor, raw, args)

      is_map(args["outboundCall"]) and expected_error(raw) != nil ->
        check_failed_call(processor, raw, args)

      true ->
        :ok
    end

    :ok
  end

  defp expected(raw), do: raw["expect"] || %{}
  defp expected_error(raw), do: raw["expectError"] || expected(raw)["error"]

  # -- catalog ----------------------------------------------------------------------

  defp build_catalog(raw, args) do
    metadata = args["functionMetadata"] || %{}
    schemas = Map.new(metadata, fn {name, meta} -> {name, function_schema(name, meta)} end)

    document = %{
      "catalogId" => catalog_id(raw, args),
      "components" => %{},
      "functions" => schemas
    }

    version =
      args["catalogVersion"] || get_in(raw, ["catalog", "protocolVersion"]) ||
        raw["protocolVersion"] || "v1.0"

    document
    |> Catalog.from_json!(protocol_version: version)
    |> Catalog.put_implementations(Map.new(Map.keys(metadata), &{&1, implementation(&1)}))
  end

  defp catalog_id(raw, args) do
    message_catalog =
      get_in(args, ["message", "callRendererFunction", "callFunction", "catalogId"])

    expected_message =
      get_in(expected(raw), ["response", "rendererFunctionResponse", "error", "message"])

    from_message =
      if String.contains?(expected_message || "", "Catalog not found"),
        do: nil,
        else: message_catalog

    args["catalogId"] || from_message ||
      get_in(args, ["outboundCall", "callFunction", "catalogId"]) || "basic"
  end

  # The declaration of a call: `@call` plus the arguments' schema (any
  # object when the case declares none).
  defp function_schema(name, meta) do
    parameters = meta["schema"] || meta["parameters"] || %{"type" => "object"}

    %{
      "type" => "object",
      "properties" => %{"@call" => %{"const" => name}, "args" => parameters},
      "required" => ["@call"],
      "returnType" => meta["returnType"] || "any",
      "allowedCallers" => meta["allowedCallers"] || "rendererOrAgent",
      "requiresUserActivation" => meta["requiresUserActivation"] || false
    }
  end

  defp implementation("playMedia"),
    do: fn _args, _ctx -> {:ok, %{"playing" => true, "timestamp" => 0}} end

  defp implementation("openExternalUrl"), do: fn _args, _ctx -> {:ok, %{"opened" => true}} end
  defp implementation("syncState"), do: fn _args, _ctx -> {:ok, nil} end

  defp implementation("failingFunction"),
    do: fn _args, _ctx -> raise "An error occurred during function execution." end

  defp implementation("calculateTax"),
    do: fn args, _ctx -> {:ok, (args["amount"] || 0) * 0.1} end

  defp implementation(_name), do: fn _args, _ctx -> {:ok, nil} end

  # -- messages ---------------------------------------------------------------------

  defp check_message(processor, raw, args) do
    expect = expected(raw)
    options = [user_activated: args["userActivationPresent"] == true]

    cond do
      is_map(expect["error"]) ->
        assert {:error, %Error{} = error, _processor} =
                 Processor.process(processor, args["message"], options)

        Matchers.assert_error(Map.put_new(expect["error"], "category", "ValidationError"), error)

      Map.has_key?(expect, "response") ->
        assert {:ok, _processor, effects} = Processor.process(processor, args["message"], options)

        assert_responses(
          expect["response"],
          for({:rpc_response, response} <- effects, do: response)
        )

      true ->
        :ok
    end
  end

  defp assert_responses(nil, responses),
    do: assert(responses == [], "expected no response, got #{inspect(responses)}")

  defp assert_responses(expected, responses) do
    assert [actual] = responses
    assert actual["version"] == expected["version"]

    actual_response = actual["rendererFunctionResponse"]
    expected_response = expected["rendererFunctionResponse"]
    assert actual_response["functionCallId"] == expected_response["functionCallId"]

    if Map.has_key?(expected_response, "value") do
      Matchers.assert_json_equal(expected_response["value"], actual_response["value"], "value")
    end

    if is_map(expected_response["error"]) do
      assert_response_error(expected_response["error"], actual_response["error"] || %{})
    end
  end

  defp assert_response_error(expected, actual) do
    assert actual["code"] == expected["code"]

    if Map.has_key?(expected, "message") do
      assert String.contains?(actual["message"] || "", expected["message"]),
             "expected #{inspect(actual["message"])} to contain #{inspect(expected["message"])}"
    end
  end

  # -- calls to the agent -----------------------------------------------------------

  defp call(spec) do
    function = spec["callFunction"]

    %{
      "@call" => function["@call"] || function["call"],
      "catalogId" => function["catalogId"] || @basic_v1,
      "args" => function["args"]
    }
  end

  defp start_call(processor, spec) do
    options =
      [function_call_id: spec["functionCallId"], version: "v1.0"] ++
        if(spec["timeoutMs"], do: [timeout_ms: spec["timeoutMs"]], else: [])

    Processor.call_agent_function(processor, spec["surfaceId"], call(spec), options)
  end

  defp check_answered_call(processor, raw, args) do
    outbound = args["outboundCall"]
    id = outbound["functionCallId"]

    assert args["inboundResponse"]["agentFunctionResponse"]["functionCallId"] ==
             expected(raw)["correlatedCallId"]

    assert {:ok, processor, message} = start_call(processor, outbound)

    assert %{"callAgentFunction" => %{"functionCallId" => ^id, "callFunction" => function}} =
             message

    assert function["@call"] == call(outbound)["@call"]

    assert {:ok, _processor, effects} = Processor.process(processor, args["inboundResponse"])
    assert [{:rpc_settled, ^id, {:ok, value}}] = effects
    Matchers.assert_json_equal(expected(raw)["result"], value, "settled result")
  end

  defp check_failed_call(processor, raw, args) do
    outbound = args["outboundCall"]
    expected_code = expected_error_code(raw)

    cond do
      is_map(args["secondOutboundCall"]) ->
        # The first call stays pending, so reusing its id must be refused.
        assert {:ok, processor, _message} = start_call(processor, outbound)

        assert {:error, %Error{category: :rpc, code: code}} =
                 start_call(processor, args["secondOutboundCall"])

        assert code == (expected_code || "DUPLICATE")

      Map.has_key?(outbound, "timeoutMs") ->
        id = outbound["functionCallId"]
        assert {:ok, processor, _message} = start_call(processor, outbound)
        assert Processor.agent_call_timeout(processor, id) == outbound["timeoutMs"]

        # No answer arrives; the host's timer fires.
        assert {_processor, [{:rpc_settled, ^id, {:error, %Error{category: :rpc, code: code}}}]} =
                 Processor.timeout_agent_call(processor, id)

        assert code == (expected_code || "TIMEOUT")

      true ->
        flunk("handle_rpc: an outbound call expecting an error needs a second call or a timeout")
    end
  end

  defp expected_error_code(raw) do
    case expected_error(raw) do
      %{"code" => code} -> code
      _other -> nil
    end
  end
end

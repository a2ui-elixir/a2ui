defmodule A2UICore.Message.RendererToAgentTest do
  @moduledoc false
  use ExUnit.Case, async: true

  doctest A2UICore.Message.RendererToAgent

  alias A2UICore.Message.RendererToAgent
  alias A2UICore.Schema
  alias A2UICore.Schema.Source
  alias A2UICore.State.Surface

  defp validate(message) do
    registry = %{
      "common_types.json" => Source.document("v1.0", :common_types),
      "catalog.json" => Source.catalog("v1.0", :basic)
    }

    Schema.validate(message, Source.document("v1.0", :renderer_to_agent), registry: registry)
  end

  describe "action/2" do
    test "wraps the event a surface dispatches" do
      surface = Surface.new("main")

      event =
        Surface.dispatch_action(
          surface,
          %{"name" => "save", "context" => %{"a" => 1}},
          "btn",
          ~U[2026-01-02 03:04:05Z]
        )

      message = RendererToAgent.action(event)

      assert message == %{"version" => "v1.0", "action" => event}
      assert :ok = validate(message)
    end

    test "carries the version it is given" do
      assert %{"version" => "v0.9"} = RendererToAgent.action(%{}, version: "v0.9")
    end
  end

  describe "error/3" do
    test "a validation error names its surface and path" do
      message =
        RendererToAgent.error("VALIDATION_FAILED", "bad text",
          surface_id: "main",
          path: "/components/0/text"
        )

      assert message == %{
               "version" => "v1.0",
               "error" => %{
                 "code" => "VALIDATION_FAILED",
                 "message" => "bad text",
                 "surfaceId" => "main",
                 "path" => "/components/0/text"
               }
             }

      assert :ok = validate(message)
    end

    test "a generic error is about a surface or a function call" do
      by_surface = RendererToAgent.error("RENDER_FAILED", "oops", surface_id: "main")
      by_call = RendererToAgent.error("RENDER_FAILED", "oops", function_call_id: "c1")

      assert :ok = validate(by_surface)
      assert :ok = validate(by_call)
      assert %{"error" => %{"functionCallId" => "c1"}} = by_call
      refute Map.has_key?(by_call["error"], "surfaceId")
    end

    test "absent options are left out" do
      assert %{"error" => error} = RendererToAgent.error("X", "y", surface_id: "", path: nil)
      assert error == %{"code" => "X", "message" => "y"}
    end
  end

  describe "call_agent_function/4" do
    test "asks the agent to run a function" do
      call = %{"@call" => "openUrl", "args" => %{"url" => "https://example.test"}}
      message = RendererToAgent.call_agent_function("main", "call-7", call)

      assert message == %{
               "version" => "v1.0",
               "callAgentFunction" => %{
                 "surfaceId" => "main",
                 "functionCallId" => "call-7",
                 "callFunction" => call
               }
             }

      assert :ok = validate(message)
    end
  end

  describe "function_response/3" do
    test "a value, including null" do
      assert %{"rendererFunctionResponse" => %{"functionCallId" => "c1", "value" => 4}} =
               message = RendererToAgent.function_response("c1", {:ok, 4})

      assert :ok = validate(message)

      assert %{"rendererFunctionResponse" => %{"value" => nil} = body} =
               RendererToAgent.function_response("c1", {:ok, nil})

      assert Map.has_key?(body, "value")
    end

    test "an error" do
      message =
        RendererToAgent.function_response("c1", {:error, "EXECUTION_ERROR", "it broke"},
          version: "v1.0"
        )

      assert message == %{
               "version" => "v1.0",
               "rendererFunctionResponse" => %{
                 "functionCallId" => "c1",
                 "error" => %{"code" => "EXECUTION_ERROR", "message" => "it broke"}
               }
             }

      assert :ok = validate(message)
    end
  end
end

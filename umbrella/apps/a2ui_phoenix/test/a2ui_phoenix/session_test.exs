defmodule A2UIPhoenix.SessionTest do
  @moduledoc false
  use ExUnit.Case, async: true

  alias A2UICore.Catalog.Basic
  alias A2UICore.Error
  alias A2UICore.Resolution.{Node, NodeResolver}
  alias A2UICore.State.Surface
  alias A2UICore.Validation.Config
  alias A2UIPhoenix.Session

  @v1 "https://a2ui.org/specification/v1_0/catalogs/basic/catalog.json"
  @v09 "https://a2ui.org/specification/v0_9/catalogs/basic/catalog.json"
  @now ~U[2026-10-14 09:30:00Z]

  defp new(options \\ []),
    do:
      Session.new(
        [Basic.catalog("v1.0"), Basic.catalog("v0.9.1")],
        [clock: fn -> @now end] ++ options
      )

  defp create(id, extra \\ %{}),
    do: %{
      "version" => "v1.0",
      "createSurface" => Map.merge(%{"surfaceId" => id, "catalogId" => @v1}, extra)
    }

  defp components(id, components),
    do: %{
      "version" => "v1.0",
      "updateComponents" => %{"surfaceId" => id, "components" => components}
    }

  defp data(id, path, value),
    do: %{
      "version" => "v1.0",
      "updateDataModel" => %{"surfaceId" => id, "path" => path, "value" => value}
    }

  defp ready(payloads, options \\ []) do
    Enum.reduce(payloads, new(options), fn payload, session ->
      {:ok, session, _effects} = Session.handle_message(session, payload)
      session
    end)
  end

  defp node_of(session, surface_id, component_id) do
    session
    |> Session.resolver(surface_id)
    |> NodeResolver.positions()
    |> Map.values()
    |> Enum.find(&(&1.component_id == component_id))
  end

  @form [
    %{"id" => "root", "component" => "Column", "children" => ["name", "go"]},
    %{
      "id" => "name",
      "component" => "TextField",
      "label" => "Name",
      "value" => %{"@path" => "/name"}
    },
    %{"id" => "go_text", "component" => "Text", "text" => "Go"},
    %{
      "id" => "go",
      "component" => "Button",
      "child" => "go_text",
      "action" => %{
        "event" => %{"name" => "submit", "context" => %{"who" => %{"@path" => "/name"}}}
      }
    }
  ]

  describe "handle_message/3" do
    test "creating a surface resolves its tree and reports the processor's effects" do
      session = new()

      assert {:ok, session, effects} =
               Session.handle_message(session, [create("main"), components("main", @form)])

      assert {:surface_created, "main"} in effects
      assert {:components_updated, "main", ["root", "name", "go_text", "go"]} in effects
      assert %Surface{id: "main"} = Session.surface(session, "main")
      assert [%Surface{}] = Session.surfaces(session)

      assert %Node{component_id: "root", type: "Column"} =
               NodeResolver.root(Session.resolver(session, "main"))
    end

    test "data changes re-resolve bindings" do
      session = ready([create("main"), components("main", @form), data("main", "/name", "Ada")])
      assert %Node{props: %{"value" => %{value: "Ada"}}} = node_of(session, "main", "name")

      {:ok, session, _effects} = Session.handle_message(session, data("main", "/name", "Grace"))
      assert %Node{props: %{"value" => %{value: "Grace"}}} = node_of(session, "main", "name")
    end

    test "deleting a surface drops its tree; recreating it starts afresh" do
      session = ready([create("main"), components("main", @form)])

      {:ok, session, effects} =
        Session.handle_message(session, %{
          "version" => "v1.0",
          "deleteSurface" => %{"surfaceId" => "main"}
        })

      assert effects == [{:surface_deleted, "main"}]
      assert Session.resolver(session, "main") == nil
    end

    test "a surface deleted and recreated in one payload gets a new tree" do
      session = ready([create("main"), components("main", @form)])

      {:ok, session, _effects} =
        Session.handle_message(session, [
          %{"version" => "v1.0", "deleteSurface" => %{"surfaceId" => "main"}},
          create("main"),
          components("main", [%{"id" => "root", "component" => "Text", "text" => "new"}])
        ])

      # An updated tree would have given the replaced root a fresh ref.
      assert %Node{ref: 1, type: "Text"} = NodeResolver.root(Session.resolver(session, "main"))
    end

    test "resolver diagnostics come back as effects" do
      session = ready([create("main")])

      {:ok, _session, effects} =
        Session.handle_message(
          session,
          components("main", [%{"id" => "root", "component" => "Sparkle"}])
        )

      assert [{:diagnostic, "main", :error, %{code: "UNKNOWN_COMPONENT_TYPE"}}] =
               for({:diagnostic, _, _, _} = diagnostic <- effects, do: diagnostic)
    end

    test "a failed message reports a validation error about its surface" do
      session = ready([create("main")], validation: Config.strict())

      assert {:error, %Error{code: "VALIDATION_FAILED"} = error, session, effects} =
               Session.handle_message(
                 session,
                 components("main", [%{"id" => "root", "component" => "Text"}])
               )

      assert [{:send, %{"version" => "v1.0", "error" => report}}] = effects
      assert report["code"] == "VALIDATION_FAILED"
      assert report["surfaceId"] == "main"
      assert report["path"] == "/components/0/text"
      assert report["message"] == error.message
      assert Session.resolver(session, "main")
    end

    test "the reported path points at the failing field of the failing message" do
      session = ready([create("main")], validation: Config.strict())

      components = [
        %{"id" => "root", "component" => "Column", "children" => ["note"]},
        %{
          "id" => "note",
          "component" => "Text",
          "text" => %{"@call" => "formatNumber", "args" => %{"value" => "x"}}
        }
      ]

      assert {:error, %Error{code: "VALIDATION_FAILED"}, _session,
              [{:send, %{"error" => report}}]} =
               Session.handle_message(session, components("main", components))

      assert report["path"] == "/components/1/text/args/value"

      # Other errors carry no path.
      dangling = [%{"id" => "root", "component" => "Column", "children" => ["gone"]}]

      assert {:error, %Error{}, _session, [{:send, %{"error" => report}}]} =
               Session.handle_message(session, components("main", dangling))

      refute Map.has_key?(report, "path")
      assert report["surfaceId"] == "main"
    end

    test "operations before a failure stay applied and are resolved" do
      session = new()

      assert {:error, %Error{}, session, effects} =
               Session.handle_message(session, [
                 create("main"),
                 components("main", @form),
                 components("missing", @form)
               ])

      assert NodeResolver.root(Session.resolver(session, "main"))

      assert [{:send, %{"error" => %{"surfaceId" => "missing"}}}] =
               for({:send, _message} = send <- effects, do: send)
    end

    test "a surface deleted before a failure loses its tree" do
      session = ready([create("main"), components("main", @form)])

      assert {:error, %Error{}, session, _effects} =
               Session.handle_message(session, [
                 %{"version" => "v1.0", "deleteSurface" => %{"surfaceId" => "main"}},
                 components("missing", @form)
               ])

      assert Session.resolver(session, "main") == nil
    end

    test "an error without a surface is reported for the one surface the payload is about" do
      untyped = [create("main"), components("main", [%{"id" => "root"}])]

      for payload <- [untyped, %{"messages" => untyped}] do
        assert {:error, %Error{surface_id: nil}, _session, effects} =
                 Session.handle_message(new(), payload)

        assert [{:send, %{"error" => %{"surfaceId" => "main"}}}] =
                 for({:send, _} = send <- effects, do: send)
      end
    end

    test "an error about no particular surface is not reported" do
      assert {:error, %Error{}, _session, []} =
               Session.handle_message(new(), %{"nonsense" => true})
    end

    test "a renderer function call is answered" do
      session = ready([create("main")])

      call = %{
        "version" => "v1.0",
        "callRendererFunction" => %{
          "functionCallId" => "c1",
          "callFunction" => %{
            "@call" => "formatString",
            "catalogId" => @v1,
            "args" => %{"value" => "hi"}
          }
        }
      }

      assert {:ok, _session, effects} = Session.handle_message(session, call)
      assert [{:send, %{"rendererFunctionResponse" => %{"functionCallId" => "c1"}}}] = effects
    end
  end

  describe "write/5" do
    test "user input lands in the data model and the tree" do
      session = ready([create("main"), components("main", @form)])
      ref = node_of(session, "main", "name").ref

      assert {:ok, session, effects} = Session.write(session, "main", ref, "value", "Ada")
      assert {:data_model_updated, "main", "/name"} in effects
      assert {:ok, "Ada"} = Surface.get_data(Session.surface(session, "main"), "/name")
      assert %Node{props: %{"value" => %{value: "Ada"}}} = node_of(session, "main", "name")
    end

    test "a property that is not a binding, a gone node or surface is an error" do
      session = ready([create("main"), components("main", @form)])
      ref = node_of(session, "main", "name").ref

      assert {:error, %Error{code: "NOT_WRITABLE"}} =
               Session.write(session, "main", ref, "label", "x")

      assert {:error, %Error{code: "NODE_NOT_FOUND"}} =
               Session.write(session, "main", 999, "value", "x")

      assert {:error, %Error{code: "INTEGRITY_ERROR"}} =
               Session.write(session, "nope", ref, "value", "x")
    end
  end

  describe "invoke/4" do
    test "an event action becomes an action message" do
      session = ready([create("main"), components("main", @form), data("main", "/name", "Ada")])
      ref = node_of(session, "main", "go").ref

      assert {:ok, ^session, [{:send, message}]} = Session.invoke(session, "main", ref, "action")

      assert message == %{
               "version" => "v1.0",
               "action" => %{
                 "name" => "submit",
                 "surfaceId" => "main",
                 "sourceComponentId" => "go",
                 "timestamp" => "2026-10-14T09:30:00Z",
                 "context" => %{"who" => "Ada"}
               }
             }
    end

    test "a v0.9 surface speaks v0.9" do
      form = [
        %{
          "id" => "root",
          "component" => "Button",
          "child" => "t",
          "action" => %{"event" => %{"name" => "go"}}
        },
        %{"id" => "t", "component" => "Text", "text" => "Go"}
      ]

      session =
        ready([
          %{"version" => "v0.9", "createSurface" => %{"surfaceId" => "old", "catalogId" => @v09}},
          %{
            "version" => "v0.9",
            "updateComponents" => %{"surfaceId" => "old", "components" => form}
          }
        ])

      ref = node_of(session, "old", "root").ref

      assert {:ok, _session, [{:send, %{"version" => "v0.9", "action" => _}}]} =
               Session.invoke(session, "old", ref, "action")
    end

    test "openUrl opens; other function calls just run" do
      open = %{
        "functionCall" => %{"@call" => "openUrl", "args" => %{"url" => %{"@path" => "/url"}}}
      }

      other = %{"functionCall" => %{"@call" => "formatString", "args" => %{"value" => "x"}}}

      bad = %{
        "functionCall" => %{"@call" => "openUrl", "args" => %{"url" => "javascript:alert(1)"}}
      }

      session =
        ready([
          create("main"),
          data("main", "/url", "https://a2ui.org/docs"),
          components("main", [
            %{"id" => "root", "component" => "Row", "children" => ["open", "other", "bad"]},
            %{"id" => "t", "component" => "Text", "text" => "x"},
            %{"id" => "open", "component" => "Button", "child" => "t", "action" => open},
            %{"id" => "other", "component" => "Button", "child" => "t", "action" => other},
            %{"id" => "bad", "component" => "Button", "child" => "t", "action" => bad}
          ])
        ])

      invoke = fn id ->
        Session.invoke(session, "main", node_of(session, "main", id).ref, "action")
      end

      assert {:ok, _session, [{:open_url, "https://a2ui.org/docs"}]} = invoke.("open")
      assert {:ok, _session, []} = invoke.("other")

      assert {:ok, _session, [{:diagnostic, "main", :error, %{code: "EXPRESSION_ERROR"}}]} =
               invoke.("bad")
    end

    test "a component whose checks fail does not act" do
      session =
        ready([
          create("main"),
          components("main", [
            %{
              "id" => "root",
              "component" => "Button",
              "child" => "t",
              "action" => %{"event" => %{"name" => "go"}},
              "checks" => [%{"condition" => false, "message" => "Not yet."}]
            },
            %{"id" => "t", "component" => "Text", "text" => "Go"}
          ])
        ])

      ref = node_of(session, "main", "root").ref

      assert {:error, %Error{code: "COMPONENT_INVALID"}} =
               Session.invoke(session, "main", ref, "action")

      assert {:error, %Error{code: "NODE_NOT_FOUND"}} =
               Session.invoke(session, "main", 999, "action")
    end

    test "a property that is not an action is an error" do
      session = ready([create("main"), components("main", @form)])
      ref = node_of(session, "main", "name").ref

      assert {:error, %Error{code: "NOT_AN_ACTION"}} =
               Session.invoke(session, "main", ref, "label")
    end
  end

  describe "client data and lifecycle" do
    test "client_data_model/2 has the surfaces that asked for it" do
      session =
        ready([
          create("shared", %{"sendDataModel" => true}),
          data("shared", "/a", 1),
          create("private")
        ])

      assert {:ok, %{"version" => "v1.0", "surfaces" => %{"shared" => %{"a" => 1}}}} =
               Session.client_data_model(session)
    end

    test "dispose/1 drops the trees and settles pending calls" do
      session = ready([create("main"), components("main", @form)])

      {:ok, processor, _message} =
        A2UICore.Processor.call_agent_function(session.processor, "main", %{
          "@call" => "lookup",
          "catalogId" => @v1,
          "args" => %{}
        })

      session = %{session | processor: processor}

      assert {session, [{:rpc_settled, "call-1", {:error, %Error{code: "CANCELLED"}}}]} =
               Session.dispose(session)

      assert Session.resolver(session, "main") == nil
      assert Session.surface(session, "main")
    end

    test "without a clock the timestamp is now" do
      session = Session.new([Basic.catalog("v1.0")])

      {:ok, session, _effects} =
        Session.handle_message(session, [create("main"), components("main", @form)])

      ref = node_of(session, "main", "go").ref

      assert {:ok, _session, effects} = Session.invoke(session, "main", ref, "action")

      assert [{:send, %{"action" => %{"timestamp" => timestamp}}}] =
               for({:send, _} = send <- effects, do: send)

      assert {:ok, _time, 0} = DateTime.from_iso8601(timestamp)
    end
  end

  describe "agent functions" do
    @lookup %{"@call" => "lookupCity", "args" => %{"zip" => %{"@path" => "/zip"}}}

    defp lookup_surface do
      [
        create("main"),
        data("main", "/zip", "10115"),
        components("main", [
          %{"id" => "root", "component" => "Column", "children" => ["city", "go"]},
          %{"id" => "city", "component" => "Text", "text" => @lookup},
          %{
            "id" => "go",
            "component" => "Button",
            "child" => "label",
            "action" => %{
              "functionCall" => %{"@call" => "reserve", "args" => %{"city" => @lookup}}
            }
          },
          %{"id" => "label", "component" => "Text", "text" => "Reserve"}
        ])
      ]
    end

    defp response(id, outcome),
      do: %{
        "version" => "v1.0",
        "agentFunctionResponse" => Map.put(outcome, "functionCallId", id)
      }

    defp text_of(session, id), do: node_of(session, "main", id).props["text"].value

    test "a property's call goes to the agent and the response fills it in" do
      {:ok, session, effects} = Session.handle_message(new(), lookup_surface())

      assert {:send,
              %{
                "version" => "v1.0",
                "callAgentFunction" => %{
                  "surfaceId" => "main",
                  "functionCallId" => "call-1",
                  "callFunction" => %{"@call" => "lookupCity", "args" => %{"zip" => "10115"}}
                }
              }} in effects

      assert {:agent_call_sent, "call-1", 30_000} in effects
      assert %Node{busy: true} = node_of(session, "main", "city")

      {:ok, session, effects} =
        Session.handle_message(session, response("call-1", %{"value" => "Berlin"}))

      assert {:rpc_settled, "call-1", {:ok, "Berlin"}} in effects
      assert text_of(session, "city") == "Berlin"
      assert %Node{busy: false} = node_of(session, "main", "city")
      assert session.agent_calls == %{}
    end

    test "an error response or a timeout is reported and leaves the property empty" do
      {:ok, session, _effects} = Session.handle_message(new(), lookup_surface())

      {:ok, failed, effects} =
        Session.handle_message(
          session,
          response("call-1", %{"error" => %{"code" => "UNKNOWN_FUNCTION", "message" => "No."}})
        )

      assert [
               {:diagnostic, "main", :error,
                %{code: "UNKNOWN_FUNCTION", function_call_id: "call-1"}}
             ] =
               for({:diagnostic, _, _, _} = d <- effects, do: d)

      assert text_of(failed, "city") == nil

      {:ok, timed_out, effects} = Session.timeout_agent_call(session, "call-1")

      assert [{:diagnostic, "main", :error, %{code: "TIMEOUT"}}] =
               for({:diagnostic, _, _, _} = d <- effects, do: d)

      assert {:ok, ^timed_out, []} = Session.timeout_agent_call(timed_out, "call-1")
    end

    test "a function-call action sends its call each time, with the values it knows" do
      {:ok, session, _effects} = Session.handle_message(new(), lookup_surface())

      {:ok, session, _effects} =
        Session.handle_message(session, response("call-1", %{"value" => "Berlin"}))

      ref = node_of(session, "main", "go").ref

      {:ok, session, effects} = Session.invoke(session, "main", ref, "action")

      assert [
               {:send,
                %{
                  "callAgentFunction" => %{
                    "functionCallId" => "call-2",
                    "callFunction" => %{"@call" => "reserve", "args" => %{"city" => "Berlin"}}
                  }
                }},
               {:agent_call_sent, "call-2", 30_000}
             ] = effects

      {:ok, session, [{:send, %{"callAgentFunction" => %{"functionCallId" => "call-3"}}} | _]} =
        Session.invoke(session, "main", ref, "action")

      {:ok, _session, effects} =
        Session.handle_message(
          session,
          response("call-2", %{"error" => %{"code" => "EXECUTION_ERROR", "message" => "Full."}})
        )

      assert Enum.any?(
               effects,
               &match?({:diagnostic, "main", :error, %{code: "EXECUTION_ERROR"}}, &1)
             )
    end

    test "a call an event needs is sent once and remembered" do
      session =
        ready([
          create("main"),
          data("main", "/zip", "10115"),
          components("main", [
            %{
              "id" => "root",
              "component" => "Button",
              "child" => "label",
              "action" => %{"event" => %{"name" => "go", "context" => %{"city" => @lookup}}}
            },
            %{"id" => "label", "component" => "Text", "text" => "Go"}
          ])
        ])

      ref = node_of(session, "main", "root").ref
      {:ok, session, effects} = Session.invoke(session, "main", ref, "action")

      assert [
               {:send, %{"callAgentFunction" => %{"functionCallId" => "call-1"}}},
               {:agent_call_sent, "call-1", 30_000},
               {:send, %{"action" => %{"name" => "go", "context" => %{"city" => nil}}}}
             ] =
               Enum.sort_by(
                 effects,
                 &(elem(&1, 0) == :send and Map.has_key?(elem(&1, 1), "action"))
               )

      {:ok, session, _effects} =
        Session.handle_message(session, response("call-1", %{"value" => "Berlin"}))

      {:ok, _session, effects} = Session.invoke(session, "main", ref, "action")

      assert [{:send, %{"action" => %{"context" => %{"city" => "Berlin"}}}}] = effects
    end

    test "a response for a surface that is gone is only passed on" do
      {:ok, session, _effects} = Session.handle_message(new(), lookup_surface())

      {:ok, session, _effects} =
        Session.handle_message(session, %{
          "version" => "v1.0",
          "deleteSurface" => %{"surfaceId" => "main"}
        })

      assert {:ok, _session, [{:rpc_settled, "call-1", {:ok, "Berlin"}}]} =
               Session.handle_message(session, response("call-1", %{"value" => "Berlin"}))
    end

    test "after dispose, a call that cannot be sent is reported" do
      {session, _effects} = Session.dispose(new())

      {:ok, _session, effects} = Session.handle_message(session, lookup_surface())

      assert Enum.any?(effects, &match?({:diagnostic, "main", :error, %{code: "DISPOSED"}}, &1))
      refute Enum.any?(effects, &match?({:send, %{"callAgentFunction" => _}}, &1))
    end
  end
end

defmodule A2UIPhoenix.MCPAppTest do
  @moduledoc false
  use ExUnit.Case, async: true

  import Phoenix.ConnTest, only: [build_conn: 0]
  import Phoenix.LiveViewTest

  alias A2UICore.Catalog.{Basic, MCP}
  alias A2UICore.Error
  alias A2UICore.Resolution.{DataContext, NodeResolver}
  alias A2UIPhoenix.{MCPApp, Session}
  alias A2UIPhoenix.Test.{FakeMCP, HostLive}

  doctest A2UIPhoenix.MCPApp

  @endpoint A2UIPhoenix.Test.Endpoint

  @basic "https://a2ui.org/specification/v1_0/catalogs/basic/catalog.json"
  @mcp "https://a2ui.org/specification/v1_0/catalogs/mcp/catalog.json"
  @a2ui "application/a2ui+json"
  @now ~U[2026-10-14 09:30:00Z]

  defp client(results, resources \\ %{}),
    do: {FakeMCP, %{test: self(), results: results, resources: resources}}

  defp new(client, options \\ []) do
    catalogs = [Basic.catalog("v1.0"), MCP.catalog("v1.0", client: client)]
    Session.new(catalogs, [clock: fn -> @now end, mcp_client: client] ++ options)
  end

  defp message(action, body),
    do: %{"version" => "v1.0", action => Map.put(body, "surfaceId", "s")}

  defp app(extra \\ %{}) do
    Map.merge(
      %{
        "id" => "app",
        "component" => "McpApp",
        "catalogId" => @mcp,
        "htmlContent" => "url_encoded:%3Cp%3EPong%3C%2Fp%3E",
        "title" => "Pong",
        "allowedTools" => ["move"],
        "allowedFunctions" => %{
          "formatString" => %{"type" => "object", "required" => ["value"]},
          "missing" => %{}
        },
        "data" => %{
          "paths" => %{"game" => "/game", "modelContext" => "/context", "toolInput" => "/input"}
        }
      },
      extra
    )
  end

  defp app_tree(extra \\ %{}),
    do: [%{"id" => "root", "component" => "Column", "children" => ["app"]}, app(extra)]

  defp tool_button(args) do
    [
      %{"id" => "root", "component" => "Column", "children" => ["go", "app"]},
      %{"id" => "label", "component" => "Text", "text" => "Go"},
      %{
        "id" => "go",
        "component" => "Button",
        "child" => "label",
        "action" => %{
          "functionCall" => %{"@call" => "callMcpTool", "catalogId" => @mcp, "args" => args}
        }
      },
      app()
    ]
  end

  defp ready(session, components) do
    payloads = [
      message("createSurface", %{"catalogId" => @basic}),
      message("updateDataModel", %{"path" => "/", "value" => %{"game" => %{"score" => 1}}}),
      message("updateComponents", %{"components" => components})
    ]

    Enum.reduce(payloads, session, fn payload, session ->
      {:ok, session, _effects} = Session.handle_message(session, payload)
      session
    end)
  end

  defp ref(session, component_id) do
    session
    |> Session.resolver("s")
    |> NodeResolver.positions()
    |> Map.values()
    |> Enum.find(&(&1.component_id == component_id))
    |> Map.fetch!(:ref)
  end

  defp data(session, path), do: MCPApp.read(Session.surface(session, "s"), path)

  defp request(session, method, params, component_id \\ "app"),
    do: Session.mcp_app_request(session, "s", ref(session, component_id), method, params)

  describe "actions that call MCP tools" do
    test "the A2UI messages a tool returns are applied" do
      update = message("updateDataModel", %{"path" => "/status", "value" => "moved"})

      result = %{
        "content" => [
          %{
            "type" => "resource",
            "resource" => %{
              "uri" => "a2ui://u",
              "mimeType" => @a2ui,
              "text" => Jason.encode!(update)
            }
          }
        ]
      }

      session = ready(new(client(%{"move" => {:ok, result}})), tool_button(%{"name" => "move"}))

      assert {:ok, session, effects} = Session.invoke(session, "s", ref(session, "go"), "action")
      assert_received {:call_tool, "move", %{}}
      assert {:data_model_updated, "s", "/status"} in effects
      assert data(session, "/status") == "moved"
    end

    test "a tool's MCP App is written where targetDataPath says" do
      named = %{"content" => [], "_meta" => %{"ui" => %{"resourceUri" => "ui://pong"}}}

      app = %{
        "uri" => "ui://pong",
        "mimeType" => A2UICore.MCP.app_mime_type(),
        "text" => "<p>Pong</p>"
      }

      resources = %{"ui://pong" => {:ok, %{"contents" => [app]}}}
      args = %{"name" => "play", "targetDataPath" => "/pong"}
      session = ready(new(client(%{"play" => {:ok, named}}, resources)), tool_button(args))

      assert {:ok, session, _effects} = Session.invoke(session, "s", ref(session, "go"), "action")
      assert %{"htmlContent" => "<p>Pong</p>", "uri" => "ui://pong"} = data(session, "/pong")
    end

    test "messages from a UI resource do not recreate a surface that exists" do
      layout = [message("createSurface", %{"catalogId" => @basic})]
      inline = message("updateDataModel", %{"path" => "/inline", "value" => true})

      result = %{
        "_meta" => %{"ui" => %{"resourceUri" => "ui://layout"}},
        "content" => [
          %{
            "type" => "resource",
            "resource" => %{
              "uri" => "a2ui://i",
              "mimeType" => @a2ui,
              "text" => Jason.encode!(inline)
            }
          }
        ]
      }

      contents = [%{"uri" => "ui://layout", "mimeType" => @a2ui, "text" => Jason.encode!(layout)}]
      resources = %{"ui://layout" => {:ok, %{"contents" => contents}}}

      session =
        ready(
          new(client(%{"show" => {:ok, result}}, resources)),
          tool_button(%{"name" => "show"})
        )

      assert {:ok, session, effects} = Session.invoke(session, "s", ref(session, "go"), "action")
      refute Enum.any?(effects, &match?({:send, %{"error" => _}}, &1))
      assert data(session, "/inline") == true
    end

    test "messages the agent's surface rejects are reported as errors" do
      broken = message("updateComponents", %{"components" => [%{"id" => "x"}]})

      result = %{
        "content" => [
          %{
            "type" => "resource",
            "resource" => %{
              "uri" => "a2ui://b",
              "mimeType" => @a2ui,
              "text" => Jason.encode!(broken)
            }
          }
        ]
      }

      session = ready(new(client(%{"move" => {:ok, result}})), tool_button(%{"name" => "move"}))

      assert {:ok, _session, effects} = Session.invoke(session, "s", ref(session, "go"), "action")
      assert Enum.any?(effects, &match?({:send, %{"error" => _}}, &1))
    end

    test "a write the data model refuses is a diagnostic" do
      named = %{"content" => [], "_meta" => %{"ui" => %{"resourceUri" => "ui://pong"}}}
      app = %{"uri" => "ui://pong", "mimeType" => A2UICore.MCP.app_mime_type(), "text" => "<p/>"}
      resources = %{"ui://pong" => {:ok, %{"contents" => [app]}}}
      args = %{"name" => "play", "targetDataPath" => "/__proto__/x"}
      session = ready(new(client(%{"play" => {:ok, named}}, resources)), tool_button(args))

      assert {:ok, _session, effects} = Session.invoke(session, "s", ref(session, "go"), "action")
      assert [{:diagnostic, "s", :error, %{path: "/__proto__/x"}}] = effects
    end
  end

  describe "mcp_app_request/5" do
    setup do
      session =
        ready(new(client(%{"move" => {:ok, %{"content" => [], "moved" => true}}})), app_tree())

      {:ok, session: session}
    end

    test "an allowed tool call reaches the agent and the tool", %{session: session} do
      params = %{"name" => "move", "arguments" => %{"to" => 3}}
      assert {:ok, _session, [{:send, sent}], reply} = request(session, "tools/call", params)
      assert sent["action"]["name"] == "move"
      assert sent["action"]["context"] == %{"to" => 3}
      assert sent["action"]["sourceComponentId"] == "app"
      assert reply == {:result, %{"content" => [], "moved" => true}}
      assert_received {:call_tool, "move", %{"to" => 3}}
    end

    test "without an MCP client the app gets an empty result" do
      catalogs = [Basic.catalog("v1.0"), MCP.catalog("v1.0")]
      session = ready(Session.new(catalogs, clock: fn -> @now end), app_tree())

      assert {:ok, _session, [{:send, _action}], {:result, %{"content" => []}}} =
               request(session, "tools/call", %{"name" => "move"})
    end

    test "tool failures are JSON-RPC errors" do
      for {reply, message} <- [
            {{:error, "down"}, "Tool 'move' failed: down"},
            {{:error, :timeout}, "Tool 'move' failed: :timeout"},
            {{:error, %RuntimeError{message: "boom"}}, "Tool 'move' failed: boom"},
            {:raise, "Tool 'move' failed: server crashed"}
          ] do
        session = ready(new(client(%{"move" => reply})), app_tree())

        assert {:ok, _session, _effects, {:error, -32_603, ^message}} =
                 request(session, "tools/call", %{"name" => "move"})
      end

      session = ready(new(client(%{"move" => {:ok, nil}})), app_tree())

      assert {:ok, _session, _effects, {:result, %{"content" => []}}} =
               request(session, "tools/call", %{"name" => "move"})
    end

    test "tools that are not allowed, bad and unsafe calls are refused", %{session: session} do
      for {params, message} <- [
            {%{"name" => "jump"}, "Tool 'jump' is not allowed."},
            {%{"arguments" => %{}}, "The request needs a tool name and an object of arguments."},
            {%{"name" => "move", "arguments" => [1]},
             "The request needs a tool name and an object of arguments."},
            {%{"name" => "move", "arguments" => %{"constructor" => 1}},
             "Security validation error: forbidden key 'constructor'"}
          ] do
        assert {:ok, ^session, [], {:error, -32_602, ^message}} =
                 request(session, "tools/call", params)
      end

      assert {:ok, _session, [], {:error, -32_602, _message}} =
               request(session, "tools/call", nil)
    end

    test "an allowed function runs in the surface's catalogs", %{session: session} do
      assert MCPApp.read(Session.surface(session, "s"), "/__proto__") == nil
      plain = ready(new(nil), app_tree(%{"allowedFunctions" => %{"required" => %{}}}))
      required = %{"call" => "required", "args" => %{"value" => "x"}}

      assert {:ok, _session, [], {:result, %{"result" => %{"valid" => true}}}} =
               request(plain, "ui/requests/function-call", required)

      params = %{"call" => "formatString", "args" => %{"value" => "Score: ${/game/score}"}}

      assert {:ok, _session, [], {:result, %{"status" => "success", "result" => "Score: 1"}}} =
               request(session, "ui/requests/function-call", params)
    end

    test "functions that are not allowed, not found, or get bad arguments fail", %{
      session: session
    } do
      for {params, code, pattern} <- [
            {%{"call" => "openUrl", "args" => %{}}, -32_602,
             ~r/Local function 'openUrl' is not allowed/},
            {%{"call" => "formatString", "args" => %{}}, -32_602,
             ~r/Invalid arguments: 'value' is a required/},
            {%{"call" => "missing", "args" => %{}}, -32_602, ~r/Function 'missing' not found/},
            {%{"call" => "formatString", "args" => %{"value" => 1, "extra" => 2}}, -32_602,
             ~r/./},
            {%{"call" => 1}, -32_602, ~r/needs a function name/},
            {%{"call" => "formatString", "args" => %{"value" => %{"__proto__" => 1}}}, -32_602,
             ~r/Security validation error/}
          ] do
        assert {:ok, ^session, [], {:error, ^code, message}} =
                 request(session, "ui/requests/function-call", params)

        assert message =~ pattern
      end
    end

    test "a function that fails, or has no implementation, is an internal error" do
      raising =
        A2UICore.Catalog.put_implementations(Basic.catalog("v1.0"), %{
          "formatString" => fn _args, _ctx -> raise "kaput" end,
          "formatNumber" => fn _args, _ctx ->
            {:error, Error.new(:expression, "X", "no number")}
          end,
          "pluralize" => fn _args, _ctx ->
            {:ok, "many", [{:write, %{path: "/count", value: 2}}]}
          end
        })

      declared = MCP.declared("v1.0")

      session =
        ready(
          Session.new([raising, declared], clock: fn -> @now end),
          app_tree(%{
            "allowedFunctions" => %{
              "formatString" => %{},
              "formatNumber" => %{},
              "pluralize" => %{},
              "callMcpTool" => %{}
            }
          })
        )

      assert {:ok, _session, [], {:error, -32_603, "kaput"}} =
               request(session, "ui/requests/function-call", %{
                 "call" => "formatString",
                 "args" => %{"value" => "x"}
               })

      assert {:ok, _session, [], {:error, -32_603, "no number"}} =
               request(session, "ui/requests/function-call", %{
                 "call" => "formatNumber",
                 "args" => %{"value" => 1}
               })

      assert {:ok, session, [{:data_model_updated, "s", "/count"}],
              {:result, %{"result" => "many"}}} =
               request(session, "ui/requests/function-call", %{
                 "call" => "pluralize",
                 "args" => %{"value" => 2, "other" => "many"}
               })

      assert data(session, "/count") == 2

      assert {:ok, _session, [],
              {:error, -32_603, "Function 'callMcpTool' has no implementation."}} =
               request(session, "ui/requests/function-call", %{
                 "call" => "callMcpTool",
                 "args" => %{"name" => "x"}
               })
    end

    test "data model changes write the bound path", %{session: session} do
      change = %{"key" => "game", "subpath" => "/score", "value" => 5}

      assert {:ok, session, [{:data_model_updated, "s", "/game/score"}], :none} =
               request(session, "ui/notifications/data-model-change", change)

      assert data(session, "/game/score") == 5

      for params <- [
            change,
            %{"key" => "unbound", "value" => 1},
            %{"key" => "game", "value" => %{"prototype" => 1}},
            %{"value" => 1}
          ] do
        assert {:ok, ^session, [], :none} =
                 request(session, "ui/notifications/data-model-change", params)
      end

      assert {:ok, session, _effects, :none} =
               request(session, "ui/notifications/data-model-change", %{
                 "key" => "game",
                 "value" => %{"score" => 9}
               })

      assert data(session, "/game") == %{"score" => 9}
    end

    test "the model context is written to its bound path", %{session: session} do
      assert {:ok, session, [{:data_model_updated, "s", "/context"}], {:result, %{}}} =
               request(session, "ui/update-model-context", %{
                 "structuredContent" => %{"level" => 2}
               })

      assert data(session, "/context") == %{"level" => 2}

      assert {:ok, session, _effects, {:result, %{}}} =
               request(session, "ui/update-model-context", %{"content" => [%{"type" => "text"}]})

      assert data(session, "/context") == [%{"type" => "text"}]

      assert {:ok, _session, [], {:error, -32_602, _message}} =
               request(session, "ui/update-model-context", %{"content" => %{"__proto__" => 1}})

      unbound = ready(new(nil), app_tree(%{"data" => %{"paths" => %{}}}))

      assert {:ok, ^unbound, [], {:result, %{}}} =
               request(unbound, "ui/update-model-context", %{"content" => []})
    end

    test "a tool without a name still answers, with no action" do
      session = ready(new(nil), app_tree(%{"allowedTools" => [""]}))

      assert {:ok, _session, [], {:result, %{"content" => []}}} =
               request(session, "tools/call", %{"name" => ""})
    end

    test "chat messages become actions; other methods are unknown", %{session: session} do
      params = %{"role" => "user", "content" => [%{"type" => "text", "text" => "hi"}]}

      assert {:ok, _session, [{:send, %{"action" => action}}], {:result, %{}}} =
               request(session, "ui/message", params)

      assert action["name"] == "ui/message"
      assert action["context"] == params

      assert {:ok, _session, [], {:error, -32_602, _message}} =
               request(session, "ui/message", %{"content" => %{"constructor" => 1}})

      assert {:ok, _session, [], {:error, -32_601, "Method not found: ui/teleport"}} =
               request(session, "ui/teleport", %{})
    end

    test "only mounted McpApp nodes take requests" do
      session = ready(new(nil), tool_button(%{"name" => "move"}))

      assert {:error, %Error{code: "NOT_AN_MCP_APP"}} =
               request(session, "tools/call", %{"name" => "move"}, "go")

      assert {:error, %Error{code: "NODE_NOT_FOUND"}} =
               Session.mcp_app_request(session, "s", 999, "tools/call", %{})

      assert {:error, %Error{}} = Session.mcp_app_request(session, "nope", 1, "tools/call", %{})
    end
  end

  describe "helpers" do
    test "html, paths, state and change paths" do
      assert MCPApp.html(%{"htmlContent" => "<b>x</b>"}) == "<b>x</b>"
      assert MCPApp.html(%{"htmlContent" => "url_encoded:%E0%A4%A"}) == nil
      assert MCPApp.html(%{}) == nil
      assert MCPApp.reserved_keys() == ["toolInput", "toolResult", "modelContext"]
      assert A2UIPhoenix.Components.MCP.default_sandbox() == "/a2ui_phoenix/a2ui_mcp_sandbox.html"

      context = DataContext.new("/rows/1")

      assert MCPApp.paths(%{"data" => %{"paths" => %{"a" => "x", "b" => 1}}}, context) == %{
               "a" => "/rows/1/x"
             }

      assert MCPApp.paths(%{}, context) == %{}

      assert MCPApp.change_path(%{"a" => "/a/"}, "a", "/b") == "/a/b"
      assert MCPApp.change_path(%{"a" => "/a"}, "a", 3) == nil
      assert MCPApp.change_path(%{}, "a", nil) == nil
    end

    test "payload checks: depth and size" do
      deep = Enum.reduce(1..11, 1, fn _, acc -> [acc] end)
      assert MCPApp.check_payload(deep) == {:error, "payload nested deeper than 10 levels"}

      assert MCPApp.check_payload(%{"a" => String.duplicate("x", 70_000)}) ==
               {:error, "payload larger than 65536 bytes"}
    end
  end

  describe "the sandbox proxy page" do
    test "the endpoint serves it as the guide configures Plug.Static" do
      static =
        Plug.Static.init(
          at: "/a2ui_phoenix",
          from: {:a2ui_phoenix, "priv/static"},
          only: ["a2ui_mcp_sandbox.html"]
        )

      conn =
        Plug.Static.call(
          Plug.Test.conn(:get, A2UIPhoenix.Components.MCP.default_sandbox()),
          static
        )

      assert conn.status == 200
      assert ["text/html" <> _] = Plug.Conn.get_resp_header(conn, "content-type")
      assert conn.resp_body =~ "ui/notifications/sandbox-proxy-ready"

      other = Plug.Static.call(Plug.Test.conn(:get, "/a2ui_phoenix/a2ui_phoenix.js"), static)
      refute other.halted
    end
  end

  describe "rendering" do
    defp start(messages, extra \\ %{}) do
      session = Map.merge(%{"test" => self(), "messages" => messages, "mcp" => %{}}, extra)
      {:ok, view, html} = live_isolated(build_conn(), HostLive, session: session)
      {view, html}
    end

    defp surface(components) do
      [
        message("createSurface", %{"catalogId" => @basic}),
        message("updateDataModel", %{
          "path" => "/",
          "value" => %{"game" => %{"score" => 1}, "input" => %{"x" => 1}}
        }),
        message("updateComponents", %{"components" => components})
      ]
    end

    test "an McpApp renders the hook's container with what the bridge needs" do
      {view, _html} = start(surface([Map.put(app(), "id", "root")]))
      html = view |> element("[data-a2ui-id='root']") |> render()

      assert html =~ ~s(phx-hook="A2UIMcpApp")
      assert html =~ ~s(data-sandbox="/a2ui_phoenix/a2ui_mcp_sandbox.html")
      assert html =~ ~s(data-html="&lt;p&gt;Pong&lt;/p&gt;")
      assert html =~ ~s(data-title="Pong")
      assert html =~ ~s(phx-update="ignore")

      [_, state] = Regex.run(~r/data-state="([^"]*)"/, html)
      state = state |> String.replace("&quot;", ~S(")) |> Jason.decode!()
      assert state == %{"game" => %{"score" => 1}, "toolInput" => %{"x" => 1}}
    end

    test "the sandbox URL is the surface's to choose; a title is optional" do
      app =
        app(%{"id" => "root", "title" => nil, "csp" => %{"connectDomains" => ["https://a.test"]}})

      {view, _html} = start(surface([app]), %{"mcp_sandbox" => "https://sandbox.test/proxy.html"})
      html = view |> element("[data-a2ui-id='root']") |> render()

      assert html =~ ~s(data-sandbox="https://sandbox.test/proxy.html")
      assert html =~ ~s(data-title="MCP App")
      assert html =~ "connectDomains"
    end

    test "requests from the app are answered through the hook" do
      {view, _html} = start(surface([Map.put(app(), "id", "root")]))
      container = element(view, "[data-a2ui-id='root']")
      [_, ref] = Regex.run(~r/data-ref="(\d+)"/, render(container))

      render_hook(container, "a2ui:mcp_app", %{
        "ref" => ref,
        "method" => "tools/call",
        "params" => %{"name" => "move", "arguments" => %{"to" => 2}},
        "id" => 4
      })

      assert_push_event(view, "a2ui:mcp_app:reply", %{
        id: 4,
        result: %{"content" => []},
        surface_id: "s"
      })

      assert_receive {:sent, %{"action" => %{"name" => "move"}}}

      render_hook(container, "a2ui:mcp_app", %{
        "ref" => ref,
        "method" => "ui/requests/function-call",
        "params" => %{"call" => "openUrl", "args" => %{}},
        "id" => 5
      })

      assert_push_event(view, "a2ui:mcp_app:reply", %{id: 5, error: %{code: -32_602}})

      render_hook(container, "a2ui:mcp_app", %{
        "ref" => ref,
        "method" => "ui/notifications/data-model-change",
        "params" => %{"key" => "game", "value" => %{"score" => 7}}
      })

      assert render(container) =~ "score&quot;:7"
      refute_push_event(view, "a2ui:mcp_app:reply", %{id: nil})

      render_hook(container, "a2ui:mcp_app", %{
        "ref" => ref,
        "method" => "ui/notifications/data-model-change",
        "params" => %{"key" => "game", "value" => %{"score" => 8}},
        "id" => 8
      })

      refute_push_event(view, "a2ui:mcp_app:reply", %{id: 8})

      send(view.pid, {A2UIPhoenix.Surface, "s", {:mcp_app, 999, "tools/call", %{}, 9}})
      render(view)
      refute_push_event(view, "a2ui:mcp_app:reply", %{id: 9})

      render_hook(container, "a2ui:mcp_app", %{
        "ref" => "999",
        "method" => "tools/call",
        "id" => 6
      })

      render_hook(container, "a2ui:mcp_app", %{"ref" => "x", "method" => "tools/call", "id" => 7})
      refute_push_event(view, "a2ui:mcp_app:reply", %{id: 6})
    end
  end
end

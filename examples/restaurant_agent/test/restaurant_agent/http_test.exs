defmodule RestaurantAgent.HTTPTest do
  use ExUnit.Case, async: true

  import Plug.Test
  import Plug.Conn
  import RestaurantAgent.Test.A2A

  alias A2UIAgent.A2A

  @router RestaurantAgent.Router.init([])

  defp call(conn), do: RestaurantAgent.Router.call(conn, @router)

  defp post_json(path, body, headers \\ []) do
    conn =
      conn(:post, path, Jason.encode!(body)) |> put_req_header("content-type", "application/json")

    headers
    |> Enum.reduce(conn, fn {key, value}, conn -> put_req_header(conn, key, value) end)
    |> call()
  end

  defp events(body) do
    body
    |> String.split("\n\n", trim: true)
    |> Enum.flat_map(fn event ->
      for "data: " <> data <- String.split(event, "\n"), do: Jason.decode!(data)
    end)
  end

  describe "A2A" do
    test "the agent card advertises both versions of the extension and its catalogs" do
      card =
        conn(:get, "/.well-known/agent-card.json")
        |> call()
        |> Map.fetch!(:resp_body)
        |> Jason.decode!()

      assert card["name"] == "Restaurant finder"
      assert card["capabilities"]["streaming"]
      assert [v1, v09] = card["capabilities"]["extensions"]
      assert v1["uri"] == A2A.extension_uri("1.0")
      assert restaurant() in v1["params"]["supportedCatalogIds"]
      assert v09["uri"] == A2A.extension_uri("0.9")

      assert conn(:get, "/a2a") |> call() |> Map.fetch!(:resp_body) |> Jason.decode!() == card
    end

    test "message/send answers with text and A2UI parts, and activates the extension" do
      conn =
        post_json("/a2a", body(text("Find Japanese food")), [
          {"x-a2a-extensions", A2A.extension_uri("1.0")}
        ])

      assert get_resp_header(conn, "x-a2a-extensions") == [A2A.extension_uri("1.0")]
      response = Jason.decode!(conn.resp_body)
      assert response["result"]["status"]["state"] == "input-required"

      {["Here are 2 places." <> _], [create]} = answer(response)
      ids = Enum.map(create["createSurface"]["components"], & &1["component"])
      assert "Rating" in ids
      refute "RestaurantCard" in ids
    end

    test "message/stream sends the task, then the parts as they are read" do
      conn = post_json("/a2a", body(text("Italian"), :v1, method: "message/stream"))
      assert ["text/event-stream" <> _] = get_resp_header(conn, "content-type")

      [submitted | updates] = events(conn.resp_body)
      assert submitted["result"]["status"]["state"] == "submitted"
      assert List.last(updates)["result"]["final"] == true

      parts =
        Enum.flat_map(updates, &(get_in(&1, ["result", "status", "message", "parts"]) || []))

      assert Enum.any?(parts, &(&1["kind"] == "text"))

      assert [%{"createSurface" => %{"surfaceId" => "restaurants-m1"}} | _] =
               A2A.a2ui_messages(parts)
    end

    test "without capabilities the agent answers in text" do
      response =
        post_json("/a2a", body(text("Italian"), :none))
        |> Map.fetch!(:resp_body)
        |> Jason.decode!()

      assert {["I can find restaurants" <> _], []} = answer(response)
    end

    test "the Express endpoint answers once the model has finished" do
      conn = post_json("/a2a/express", body(text("Indian"), :v1, method: "message/stream"))
      updates = conn.resp_body |> events() |> tl()

      with_parts = Enum.filter(updates, &get_in(&1, ["result", "status", "message", "parts"]))
      assert [%{"result" => %{"status" => %{"message" => %{"parts" => parts}}}} | _] = with_parts
      # One catalog: the surface has a default, for the calls in templates.
      assert [%{"createSurface" => %{"catalogId" => catalog_id, "components" => [_ | _]}}] =
               A2A.a2ui_messages(parts)

      assert catalog_id == basic()
    end
  end

  describe "pages" do
    test "the prompt shows the catalogs and the macro" do
      prompt = conn(:get, "/prompt") |> call() |> Map.fetch!(:resp_body)
      assert prompt =~ "RestaurantCard"
      assert prompt =~ "checkAvailability"

      assert conn(:get, "/prompt?format=express") |> call() |> Map.fetch!(:resp_body) =~ "Express"

      refute conn(:get, "/prompt?version=v0.9") |> call() |> Map.fetch!(:resp_body) =~
               "RestaurantCard"
    end

    test "pictures, health and unknown paths" do
      conn = conn(:get, "/images/sakura.svg") |> call()
      assert conn.status == 200
      assert ["image/svg+xml" <> _] = get_resp_header(conn, "content-type")

      assert conn(:get, "/images/nowhere.svg") |> call() |> Map.fetch!(:status) == 404
      assert conn(:get, "/healthz") |> call() |> Map.fetch!(:resp_body) == "ok"
      assert conn(:get, "/") |> call() |> Map.fetch!(:status) == 200
      assert conn(:get, "/nothing") |> call() |> Map.fetch!(:status) == 404
    end
  end

  describe "MCP" do
    defp rpc(method, params, id \\ 1),
      do:
        post_json("/mcp", %{
          "jsonrpc" => "2.0",
          "id" => id,
          "method" => method,
          "params" => params
        })

    defp result(conn), do: Jason.decode!(conn.resp_body)["result"]

    test "initialize, ping and tools/list" do
      init =
        rpc("initialize", %{
          "capabilities" => %{"a2ui" => %{"clientCapabilities" => %{"v1.0" => %{}}}}
        })
        |> result()

      assert init["serverInfo"]["name"] == "restaurant-finder"
      assert rpc("ping", %{}) |> result() == %{}

      names = rpc("tools/list", %{}) |> result() |> Map.fetch!("tools") |> Enum.map(& &1["name"])
      assert names == ["find_restaurants", "a2ui_action", "a2ui_error"]
    end

    test "a tool call returns the surface in an embedded A2UI resource" do
      meta = %{"a2ui" => %{"clientCapabilities" => capabilities(:v1)["a2uiRendererCapabilities"]}}

      result =
        rpc("tools/call", %{
          "name" => "find_restaurants",
          "arguments" => %{"query" => "french"},
          "_meta" => meta
        })
        |> result()

      assert [%{"type" => "text", "text" => "Here is one place." <> _}, %{"type" => "resource"}] =
               result["content"]

      assert {:ok, [%{"createSurface" => _}]} = A2UIAgent.MCP.a2ui_messages(result)
    end

    test "actions and errors arrive as tool calls" do
      action = action("book", "restaurants-1", %{"restaurantId" => "la-cantina"})["action"]
      result = rpc("tools/call", %{"name" => "a2ui_action", "arguments" => action}) |> result()

      # MCP cannot carry the answers to function calls back: the form makes none.
      assert {:ok, [%{"createSurface" => %{"surfaceId" => "booking-" <> _} = create}]} =
               A2UIAgent.MCP.a2ui_messages(result)

      refute inspect(create) =~ "checkAvailability"

      error = %{"code" => "VALIDATION_FAILED", "surfaceId" => "s", "message" => "bad"}
      result = rpc("tools/call", %{"name" => "a2ui_error", "arguments" => error}) |> result()
      assert [%{"text" => "Sorry, something went wrong" <> _} | _] = result["content"]

      assert %{"isError" => true} =
               rpc("tools/call", %{"name" => "find_restaurants", "arguments" => %{}}) |> result()

      assert %{"isError" => true} =
               rpc("tools/call", %{"name" => "a2ui_action", "arguments" => %{"name" => "x"}})
               |> result()
    end

    test "unknown tools and methods, notifications and bad requests" do
      assert %{"error" => %{"code" => -32_602}} =
               rpc("tools/call", %{"name" => "fly"}) |> Map.fetch!(:resp_body) |> Jason.decode!()

      assert %{"error" => %{"code" => -32_601}} =
               rpc("resources/list", %{}) |> Map.fetch!(:resp_body) |> Jason.decode!()

      assert post_json("/mcp", %{"jsonrpc" => "2.0", "method" => "notifications/initialized"}).status ==
               202

      assert %{"error" => %{"code" => -32_600}} =
               post_json("/mcp", %{"hello" => 1}) |> Map.fetch!(:resp_body) |> Jason.decode!()
    end
  end

  describe "AG-UI" do
    test "a run answers with text and a snapshot of each surface" do
      input = %{
        "threadId" => "t",
        "runId" => "r1",
        "messages" => [%{"id" => "1", "role" => "user", "content" => "Italian please"}]
      }

      types = post_json("/agui", input).resp_body |> events() |> Enum.map(& &1["type"])

      assert types == [
               "RUN_STARTED",
               "TEXT_MESSAGE_START",
               "TEXT_MESSAGE_CONTENT",
               "TEXT_MESSAGE_END",
               "ACTIVITY_SNAPSHOT",
               "RUN_FINISHED"
             ]
    end

    test "an action extends the surfaces the renderer sends back in its state" do
      booking = [
        %{
          "version" => "v1.0",
          "createSurface" => %{"surfaceId" => "booking-x", "catalogId" => basic()}
        }
      ]

      submitted = %{
        "restaurant" => "Sakura",
        "name" => "Ada",
        "email" => "ada@example.com",
        "date" => "2026-10-17T19:30",
        "partySize" => 2
      }

      input = %{
        "threadId" => "t",
        "runId" => "r2",
        "messages" => [],
        "state" => %{"a2uiSurfaces" => %{"booking-x" => booking}},
        "forwardedProps" => %{
          "a2uiAction" => %{
            "userAction" =>
              action("submit_booking", "booking-x", %{"booking" => submitted})["action"]
          }
        }
      }

      [snapshot] =
        post_json("/agui", input).resp_body
        |> events()
        |> Enum.filter(&(&1["type"] == "ACTIVITY_SNAPSHOT"))

      assert snapshot["messageId"] == "a2ui-surface-booking-x"

      assert keys(snapshot["content"]["a2ui_operations"]) == [
               "createSurface",
               "updateComponents",
               "updateDataModel"
             ]
    end

    test "a renderer without a catalog in common fails the run" do
      input = %{
        "runId" => "r3",
        "messages" => [],
        "forwardedProps" => %{
          "a2uiRendererCapabilities" => %{"v1.0" => %{"supportedCatalogIds" => ["x"]}}
        }
      }

      assert ["RUN_STARTED", "RUN_ERROR"] =
               post_json("/agui", input).resp_body |> events() |> Enum.map(& &1["type"])
    end
  end

  describe "server-sent events" do
    defp sse(conn) do
      conn.resp_body
      |> String.split("\n\n", trim: true)
      |> Enum.map(fn event ->
        lines = String.split(event, "\n")

        id =
          Enum.find_value(lines, fn
            "id: " <> id -> id
            _ -> nil
          end)

        data =
          Enum.find_value(lines, fn
            "data: " <> data -> Jason.decode!(data)
            _ -> nil
          end)

        {id, data}
      end)
      |> Enum.reject(&match?({nil, nil}, &1))
    end

    test "each message is an event with an id, and a reconnect resumes after the last one" do
      [{"1", %{"version" => "v0.9", "createSurface" => _}}, {"2", _}, {"3", _}] =
        conn(:get, "/events?q=italian&version=v0.9") |> call() |> sse()

      resumed =
        conn(:get, "/events?q=italian&version=v0.9")
        |> put_req_header("last-event-id", "1")
        |> call()
        |> sse()

      assert Enum.map(resumed, &elem(&1, 0)) == ["2", "3"]

      assert [{"1", %{"version" => "v1.0"}}] = conn(:get, "/events?q=italian") |> call() |> sse()
    end
  end
end

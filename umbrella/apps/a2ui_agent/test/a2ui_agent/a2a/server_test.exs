defmodule A2UIAgent.A2A.ServerTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias A2UIAgent.{A2A, CatalogConfig, Express, Generator, RequestProcessor}
  alias A2UIAgent.A2A.{Request, Server}
  alias A2UIAgent.Test.Fixtures
  alias A2UICore.Catalog

  @clock "2026-10-14T12:00:00Z"

  defmodule EchoAgent do
    @behaviour A2UIAgent.A2A.Agent

    @impl true
    def run(%Request{text: text}), do: {:ok, "You said: " <> text}
  end

  defp options(extra \\ []),
    do: [id_generator: fn -> "generated" end, clock: fn -> @clock end] ++ extra

  defp body(method, message, id \\ 1),
    do: %{"jsonrpc" => "2.0", "id" => id, "method" => method, "params" => %{"message" => message}}

  defp user(parts, metadata \\ nil) do
    message = %{"kind" => "message", "role" => "user", "messageId" => "m1", "parts" => parts}
    if metadata, do: Map.put(message, "metadata", metadata), else: message
  end

  defp v1_capabilities,
    do: %{
      "a2uiRendererCapabilities" => %{"v1.0" => %{"supportedCatalogIds" => [Fixtures.basic_id()]}}
    }

  defp generator(catalog), do: Generator.new([CatalogConfig.new(catalog)])

  defp output(messages),
    do: "Here you go.\n<a2ui-json>\n#{Jason.encode!(messages)}\n</a2ui-json>\nAnything else?"

  defp parts(response), do: get_in(response, ["result", "status", "message", "parts"])

  defp reporting(answer) do
    test = self()

    fn request ->
      send(test, {:request, request})
      answer
    end
  end

  describe "JSON-RPC" do
    test "a body that is not a JSON-RPC 2.0 request is an invalid request" do
      for {body, id} <- [
            {"text", nil},
            {%{"id" => 7, "method" => "message/send"}, 7},
            {%{"jsonrpc" => "2.0", "id" => "r1"}, "r1"},
            {%{"jsonrpc" => "2.0", "id" => %{}, "method" => 1}, nil}
          ] do
        assert {:reply, %{"jsonrpc" => "2.0", "id" => ^id, "error" => %{"code" => -32_600}}, []} =
                 Server.handle(body, EchoAgent)
      end
    end

    test "another method is not found" do
      assert {:reply, %{"id" => 2, "error" => %{"code" => -32_601, "message" => message}}, []} =
               Server.handle(%{"jsonrpc" => "2.0", "id" => 2, "method" => "tasks/get"}, EchoAgent)

      assert message =~ "tasks/get"
    end

    test "a request without a message object has invalid params" do
      for params <- [nil, %{}, %{"message" => "Hi"}] do
        body = %{"jsonrpc" => "2.0", "id" => 3, "method" => "message/send", "params" => params}

        assert {:reply, %{"id" => 3, "error" => %{"code" => -32_602}}, []} =
                 Server.handle(body, EchoAgent)
      end
    end

    test "error responses carry the request id" do
      assert Server.error_response(5, -32_700, "Parse error") == %{
               "jsonrpc" => "2.0",
               "id" => 5,
               "error" => %{"code" => -32_700, "message" => "Parse error"}
             }
    end
  end

  describe "message/send" do
    test "answers with the finished task, in text without a generator" do
      agent = reporting({:ok, "  Hello there.  "})

      assert {:reply, response, []} =
               Server.handle(body("message/send", user([A2A.text_part("Hi")])), agent, options())

      assert response == %{
               "jsonrpc" => "2.0",
               "id" => 1,
               "result" => %{
                 "kind" => "task",
                 "id" => "generated",
                 "contextId" => "generated",
                 "status" => %{
                   "state" => "input-required",
                   "timestamp" => @clock,
                   "message" => %{
                     "kind" => "message",
                     "role" => "agent",
                     "messageId" => "generated",
                     "taskId" => "generated",
                     "contextId" => "generated",
                     "parts" => [A2A.text_part("Hello there.")]
                   }
                 }
               }
             }

      assert_received {:request, %Request{text: "Hi", processor: nil, version: nil}}
    end

    test "keeps the client's task and context" do
      message = Map.merge(user([]), %{"taskId" => "t1", "contextId" => "c1"})

      assert {:reply, %{"result" => %{"id" => "t1", "contextId" => "c1"} = task}, []} =
               Server.handle(body("message/send", message), EchoAgent, options())

      assert %{"taskId" => "t1", "contextId" => "c1"} = task["status"]["message"]
    end

    test "an empty answer has a status without a message" do
      assert {:reply, response, []} =
               Server.handle(body("message/send", user([])), fn _ -> {:ok, "  "} end, options())

      assert response["result"]["status"] == %{"state" => "input-required", "timestamp" => @clock}
    end

    test "answers in A2UI parts for the renderer's capabilities" do
      [create, update] = Fixtures.surface()
      agent = reporting({:ok, output([create, update])})
      message = user([A2A.text_part("Show me")], v1_capabilities())

      assert {:reply, response, []} =
               Server.handle(
                 body("message/send", message),
                 agent,
                 options(generator: generator(Fixtures.basic()))
               )

      assert parts(response) == [
               A2A.text_part("Here you go."),
               A2A.a2ui_part(create, "v1.0"),
               A2A.a2ui_part(update, "v1.0"),
               A2A.text_part("Anything else?")
             ]

      assert_received {:request,
                       %Request{
                         processor: %RequestProcessor{},
                         version: "v1.0",
                         capabilities: caps
                       }}

      assert caps == v1_capabilities()["a2uiRendererCapabilities"]
    end

    test "serves each renderer with the generator for its protocol version" do
      v091 = Fixtures.basic_v09()
      capabilities = %{"v0.9" => %{"supportedCatalogIds" => [v091.catalog_id]}}

      messages = [
        Fixtures.create("s1", v091.catalog_id, "v0.9.1"),
        Fixtures.update([Fixtures.text("root", "Hi")], "s1", "v0.9.1")
      ]

      assert {:reply, response, []} =
               Server.handle(
                 body("message/send", user([], %{"a2uiClientCapabilities" => capabilities})),
                 fn _ -> {:ok, output(messages)} end,
                 options(generator: [generator(Fixtures.basic()), generator(v091)])
               )

      assert [_text, create, update, _more] = parts(response)
      assert create == A2A.a2ui_part(hd(messages), "v0.9.1")
      assert update["metadata"]["mimeType"] == "application/a2ui+json"
    end

    test "marks the parts of v0.9 messages with the older MIME type" do
      id = "https://example.com/catalogs/v0_9.json"
      catalog = Fixtures.catalog(id, ["Text"], "v0.9")

      messages = [
        Fixtures.create("s1", id, "v0.9"),
        Fixtures.update([Fixtures.text("root", "Hi")], "s1", "v0.9")
      ]

      assert {:reply, response, []} =
               Server.handle(
                 body("message/send", user([])),
                 fn _ -> {:ok, output(messages)} end,
                 options(
                   generator: generator(catalog),
                   default_capabilities: %{"v0.9" => %{"supportedCatalogIds" => [id]}}
                 )
               )

      assert [_text, create, _update, _more] = parts(response)
      assert create["metadata"]["mimeType"] == "application/json+a2ui"
    end

    test "negotiates the default capabilities for a message without any" do
      [create, update] = Fixtures.surface()

      assert {:reply, response, []} =
               Server.handle(
                 body("message/send", user([])),
                 fn _ -> {:ok, output([create, update])} end,
                 options(
                   generator: generator(Fixtures.basic()),
                   default_capabilities: v1_capabilities()["a2uiRendererCapabilities"]
                 )
               )

      assert A2A.a2ui_messages(parts(response)) == [create, update]
    end

    test "fails the task when the capabilities name none of the agent's catalogs" do
      capabilities = %{
        "a2uiRendererCapabilities" => %{
          "v1.0" => %{"supportedCatalogIds" => ["https://example.com/unknown.json"]}
        }
      }

      assert {:reply, response, []} =
               Server.handle(
                 body("message/send", user([], capabilities)),
                 fn _ -> flunk("the agent runs only for a negotiated renderer") end,
                 options(generator: generator(Fixtures.basic()))
               )

      assert response["result"]["status"]["state"] == "failed"
      assert [%{"kind" => "text", "text" => text}] = parts(response)
      assert text =~ "No client-supported catalog"
    end

    test "fails the task with the agent's error" do
      for {reason, text} <- [
            {"model unavailable", "model unavailable"},
            {%RuntimeError{message: "boom"}, "boom"},
            {:timeout, ":timeout"}
          ] do
        assert {:reply, response, []} =
                 Server.handle(
                   body("message/send", user([])),
                   fn _ -> {:error, reason} end,
                   options()
                 )

        assert response["result"]["status"]["state"] == "failed"
        assert parts(response) == [A2A.text_part(text)]
      end
    end

    test "ends the task in the state the agent or the options give" do
      assert {:reply, response, []} =
               Server.handle(
                 body("message/send", user([])),
                 fn _ -> {:ok, "Booked.", "completed"} end,
                 options()
               )

      assert response["result"]["status"]["state"] == "completed"

      assert {:reply, response, []} =
               Server.handle(
                 body("message/send", user([])),
                 EchoAgent,
                 options(final_state: "completed")
               )

      assert response["result"]["status"]["state"] == "completed"
    end

    test "joins streamed chunks into one answer" do
      assert {:reply, response, []} =
               Server.handle(
                 body("message/send", user([])),
                 fn _ -> {:ok, Stream.map(["Hel", "lo"], & &1)} end,
                 options()
               )

      assert parts(response) == [A2A.text_part("Hello")]
    end

    test "serves an agent module" do
      assert {:reply, response, []} =
               Server.handle(body("message/send", user([A2A.text_part("Hi")])), EchoAgent)

      assert parts(response) == [A2A.text_part("You said: Hi")]

      assert response["result"]["id"] =~
               ~r/^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/

      assert {:ok, _datetime, 0} =
               DateTime.from_iso8601(response["result"]["status"]["timestamp"])
    end

    test "rejects an agent answer of another shape" do
      assert_raise ArgumentError, ~r/an A2A agent returns/, fn ->
        Server.handle(body("message/send", user([])), fn _ -> :ok end, options())
      end
    end

    test "answers a response that does not parse in text" do
      response =
        "Here is a chart:\n<a2ui-json>\n[{ “beginRendering”: { MISSING\n</a2ui-json>\nOops."

      log =
        capture_log(fn ->
          assert {:reply, reply, []} =
                   Server.handle(
                     body("message/send", user([], v1_capabilities())),
                     fn _ -> {:ok, "\n" <> response <> "\n"} end,
                     options(generator: generator(Fixtures.basic()))
                   )

          assert parts(reply) == [A2A.text_part(response)]
        end)

      assert log =~ "Failed to parse A2UI response"
    end
  end

  describe "the request" do
    test "carries the message's text, A2UI events, data model and capabilities" do
      action = %{
        "version" => "v1.0",
        "action" => %{
          "name" => "submit",
          "surfaceId" => "s1",
          "sourceComponentId" => "send",
          "timestamp" => @clock,
          "context" => %{"name" => "Ada"}
        }
      }

      data_model = %{"version" => "v1.0", "surfaces" => %{"s1" => %{"name" => "Ada"}}}

      message =
        [
          A2A.text_part("Sub"),
          %{"text" => "mit"},
          %{"kind" => "file", "text" => "not text"},
          A2A.a2ui_part(action, "v1.0"),
          %{"kind" => "data", "data" => %{"useStreaming" => false}}
        ]
        |> user(Map.put(v1_capabilities(), "a2uiRendererDataModel", data_model))
        |> Map.merge(%{"taskId" => "t1", "contextId" => "c1"})

      Server.handle(body("message/send", message, "r1"), reporting({:ok, ""}), options())

      assert_received {:request, request}

      assert %Request{
               id: "r1",
               method: "message/send",
               task_id: "t1",
               context_id: "c1",
               text: "Submit",
               events: [^action],
               data_model: ^data_model,
               extensions: [],
               activated: nil
             } = request

      assert request.message == message
      assert request.capabilities == v1_capabilities()["a2uiRendererCapabilities"]
    end

    test "reads the metadata keys of v0.9 renderers, and both kinds at once" do
      v09 = %{"v0.9" => %{"supportedCatalogIds" => ["a"]}}
      v1 = %{"v1.0" => %{"supportedCatalogIds" => ["b"]}}
      data_model = %{"version" => "v0.9", "surfaces" => %{}}

      metadata = %{
        "a2uiClientCapabilities" => v09,
        "a2uiRendererCapabilities" => v1,
        "a2uiClientDataModel" => data_model
      }

      Server.handle(body("message/send", user([], metadata)), reporting({:ok, ""}), options())

      assert_received {:request, %Request{capabilities: capabilities, data_model: ^data_model}}
      assert capabilities == Map.merge(v09, v1)

      Server.handle(body("message/send", user([], "not a map")), reporting({:ok, ""}), options())
      assert_received {:request, %Request{capabilities: nil, data_model: nil, events: []}}
    end

    test "activates the newest requested extension the agent advertises" do
      v1 = A2A.extension_uri("1.0")
      v091 = A2A.extension_uri("0.9.1")

      body =
        "message/send"
        |> body(Map.put(user([]), "extensions", [v091]))
        |> put_in(["params", "metadata"], %{"X-A2A-Extensions" => v1})

      assert {:reply, _response, [^v1]} =
               Server.handle(
                 body,
                 reporting({:ok, ""}),
                 options(extensions: ["https://example.com/x, " <> v091], advertised: [v1, v091])
               )

      assert_received {:request, %Request{extensions: [^v091, ^v1], activated: {^v1, "1.0"}}}

      assert {:reply, _response, []} = Server.handle(body, reporting({:ok, ""}), options())
      assert_received {:request, %Request{extensions: [^v1, ^v091], activated: nil}}
    end
  end

  describe "message/stream" do
    test "sends the task, a working update for each chunk with parts, then the final status" do
      [create, update] = Fixtures.surface()

      chunks =
        output([create, update])
        |> String.graphemes()
        |> Enum.chunk_every(7)
        |> Enum.map(&Enum.join/1)

      assert {:stream, events, []} =
               Server.handle(
                 body("message/stream", user([], v1_capabilities())),
                 fn _ -> {:ok, chunks} end,
                 options(generator: generator(Fixtures.basic()))
               )

      events = Enum.to_list(events)
      assert Enum.all?(events, &match?(%{"jsonrpc" => "2.0", "id" => 1}, &1))
      [submitted | rest] = Enum.map(events, & &1["result"])
      {working, [final]} = Enum.split(rest, -1)

      assert submitted == %{
               "kind" => "task",
               "id" => "generated",
               "contextId" => "generated",
               "status" => %{"state" => "submitted", "timestamp" => @clock}
             }

      assert final == %{
               "kind" => "status-update",
               "taskId" => "generated",
               "contextId" => "generated",
               "status" => %{"state" => "input-required", "timestamp" => @clock},
               "final" => true
             }

      assert working != []

      for update <- working do
        assert %{"kind" => "status-update", "final" => false, "status" => %{"state" => "working"}} =
                 update
      end

      parts = Enum.flat_map(working, & &1["status"]["message"]["parts"])
      texts = for %{"kind" => "text", "text" => text} <- parts, do: text
      assert Enum.join(texts) == "Here you go.Anything else?"

      messages = A2A.a2ui_messages(parts)
      assert create in messages
      assert List.last(messages) == update
    end

    test "answers a format read only when complete once, at the end" do
      chunks = ["Here.\n<a2ui>\nroot = Te", "xt(\"Hi\")\n</a2ui>"]

      generator =
        Generator.new([CatalogConfig.new(Catalog.Basic.catalog("v1.0"))], format: Express)

      assert {:stream, events, []} =
               Server.handle(
                 body("message/stream", user([], v1_capabilities())),
                 fn _ -> {:ok, chunks} end,
                 options(generator: generator)
               )

      assert [_task, working, final] = Enum.map(events, & &1["result"])
      assert final["final"] == true
      parts = working["status"]["message"]["parts"]
      assert [%{"kind" => "text", "text" => "Here."}, _a2ui] = parts
      assert [%{"createSurface" => %{"surfaceId" => "main"}}] = A2A.a2ui_messages(parts)
    end

    test "runs the agent once the stream is read past the task" do
      assert {:stream, events, []} =
               Server.handle(body("message/stream", user([])), reporting({:ok, "Hi"}), options())

      assert [%{"result" => %{"kind" => "task"}}] = Enum.take(events, 1)
      refute_received {:request, _request}

      assert [_task, working, _final] = Enum.to_list(events)
      assert_received {:request, %Request{method: "message/stream"}}
      assert working["result"]["status"]["message"]["parts"] == [A2A.text_part("Hi")]
    end

    test "trims a text-only answer at its ends" do
      chunks = ["  ", " Hel", "lo ", "  ", "world  ", "  "]

      assert {:stream, events, []} =
               Server.handle(
                 body("message/stream", user([])),
                 fn _ -> {:ok, chunks} end,
                 options()
               )

      texts =
        for %{"result" => %{"status" => %{"state" => "working", "message" => message}}} <- events,
            %{"text" => text} <- message["parts"],
            do: text

      assert texts == ["Hel", "lo", "   world"]
    end

    test "fails the task when the stream stops parsing" do
      # On the last chunk or before it.
      for chunks <- [
            ["Hi <a2ui-json>[{ nope", "</a2ui-json>"],
            ["Hi <a2ui-json>[{ nope", "</a2ui-json>", "never read"]
          ] do
        assert {:stream, events, []} =
                 Server.handle(
                   body("message/stream", user([], v1_capabilities())),
                   fn _ -> {:ok, chunks} end,
                   options(generator: generator(Fixtures.basic()))
                 )

        results = Enum.map(events, & &1["result"])

        assert %{"kind" => "status-update", "final" => true, "status" => status} =
                 List.last(results)

        assert status["state"] == "failed"
        assert [%{"kind" => "text", "text" => _error}] = status["message"]["parts"]
        assert Enum.count(results, &(&1["final"] == true)) == 1
      end
    end

    test "fails the announced task when negotiation or the agent fails" do
      capabilities = %{
        "a2uiRendererCapabilities" => %{"v1.0" => %{"supportedCatalogIds" => ["https://x.test"]}}
      }

      for {message, agent} <- [
            {user([], capabilities), fn _ -> flunk("not run") end},
            {user([]), fn _ -> {:error, "down"} end}
          ] do
        assert {:stream, events, []} =
                 Server.handle(
                   body("message/stream", message),
                   agent,
                   options(generator: generator(Fixtures.basic()))
                 )

        assert [%{"result" => task}, %{"result" => failed}] = Enum.to_list(events)
        assert task["kind"] == "task"
        assert %{"taskId" => "generated", "final" => true} = failed
        assert failed["status"]["state"] == "failed"
      end
    end

    test "ends in the state the agent gives" do
      assert {:stream, events, []} =
               Server.handle(
                 body("message/stream", user([])),
                 fn _ -> {:ok, ["Done"], "completed"} end,
                 options()
               )

      assert %{"status" => %{"state" => "completed"}, "final" => true} =
               events |> Enum.to_list() |> List.last() |> Map.fetch!("result")
    end
  end
end

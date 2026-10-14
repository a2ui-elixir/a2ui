defmodule A2UIAgent.A2A.PlugTest do
  use ExUnit.Case, async: true

  import Plug.Conn
  import Plug.Test

  alias A2UIAgent.A2A
  alias A2UIAgent.A2A.Plug, as: A2APlug
  alias A2UIAgent.Test.{ClosingAdapter, Fixtures, SSE}

  defmodule TextAgent do
    @behaviour A2UIAgent.A2A.Agent

    @impl true
    def run(request), do: {:ok, ["You said: ", request.text]}
  end

  defmodule UIAgent do
    @behaviour A2UIAgent.A2A.Agent

    alias A2UIAgent.{A2A, CatalogConfig, Generator}
    alias A2UIAgent.Test.Fixtures

    @impl true
    def run(_request),
      do: {:ok, "Here.\n<a2ui-json>#{Jason.encode!(Fixtures.surface())}</a2ui-json>"}

    @impl true
    def options, do: [generator: Generator.new([CatalogConfig.new(Fixtures.basic())])]

    @impl true
    def card do
      %{
        "name" => "UI agent",
        "capabilities" => %{
          "extensions" => [A2A.agent_extension("1.0"), A2A.agent_extension("0.9.1")]
        }
      }
    end
  end

  # Streams numbered chunks, reporting each one it is asked for.
  defmodule CountingAgent do
    @behaviour A2UIAgent.A2A.Agent

    @impl true
    def run(_request) do
      test = self()

      chunks =
        Stream.map(1..5, fn i ->
          send(test, {:pulled, i})
          "chunk #{i} "
        end)

      {:ok, chunks}
    end
  end

  # Advertises less than its card does.
  defmodule NarrowAgent do
    @behaviour A2UIAgent.A2A.Agent

    alias A2UIAgent.A2A
    alias A2UIAgent.A2A.PlugTest.UIAgent

    @impl true
    def run(_request), do: {:ok, "Hi"}

    @impl true
    def options, do: [advertised: [A2A.extension_uri("0.9.1")]]

    @impl true
    def card, do: UIAgent.card()
  end

  defp rpc(method, message, id \\ 1),
    do:
      Jason.encode!(%{
        "jsonrpc" => "2.0",
        "id" => id,
        "method" => method,
        "params" => %{"message" => message}
      })

  defp user(text, metadata \\ %{}),
    do: %{"role" => "user", "parts" => [A2A.text_part(text)], "metadata" => metadata}

  defp v1_capabilities,
    do: %{
      "a2uiRendererCapabilities" => %{"v1.0" => %{"supportedCatalogIds" => [Fixtures.basic_id()]}}
    }

  defp post(body, headers \\ []) do
    Enum.reduce(headers, conn(:post, "/a2a", body), fn {name, value}, conn ->
      put_req_header(conn, name, value)
    end)
  end

  defp call(conn, agent, options \\ []),
    do: A2APlug.call(conn, A2APlug.init([agent: agent] ++ options))

  defp json(conn), do: Jason.decode!(conn.resp_body)

  test "answers message/send with JSON" do
    conn = call(post(rpc("message/send", user("Hi"))), TextAgent)

    assert conn.status == 200
    assert get_resp_header(conn, "content-type") == ["application/json; charset=utf-8"]
    assert get_resp_header(conn, "x-a2a-extensions") == []

    assert %{"jsonrpc" => "2.0", "id" => 1, "result" => %{"kind" => "task"} = task} = json(conn)
    assert task["status"]["message"]["parts"] == [A2A.text_part("You said: Hi")]
  end

  test "answers message/stream with one server-sent event per JSON-RPC response" do
    conn = call(post(rpc("message/stream", user("Hi"), "r1")), TextAgent)

    assert conn.status == 200
    assert conn.state == :chunked
    assert get_resp_header(conn, "content-type") == ["text/event-stream; charset=utf-8"]
    assert get_resp_header(conn, "cache-control") == ["no-cache"]
    assert get_resp_header(conn, "x-accel-buffering") == ["no"]

    events = SSE.json(conn.resp_body)
    assert Enum.all?(events, &match?(%{"jsonrpc" => "2.0", "id" => "r1"}, &1))

    [submitted | rest] = Enum.map(events, & &1["result"])
    {working, [final]} = Enum.split(rest, -1)
    assert %{"kind" => "task", "status" => %{"state" => "submitted"}} = submitted
    assert %{"kind" => "status-update", "final" => true} = final

    texts =
      for %{"status" => %{"state" => "working", "message" => %{"parts" => parts}}} <- working,
          %{"text" => text} <- parts,
          do: text

    assert texts == ["You said:", " Hi"]
  end

  test "negotiates catalogs and the extension for an A2UI agent" do
    v1 = A2A.extension_uri("1.0")

    conn =
      "message/send"
      |> rpc(user("Show me", v1_capabilities()))
      |> post([{"x-a2a-extensions", "#{A2A.extension_uri("0.9.1")}, #{v1}"}])
      |> call(UIAgent)

    assert get_resp_header(conn, "x-a2a-extensions") == [v1]
    parts = json(conn)["result"]["status"]["message"]["parts"]
    assert A2A.a2ui_messages(parts) == Fixtures.surface()
  end

  test "lets the agent's options override what its card advertises" do
    v091 = A2A.extension_uri("0.9.1")
    header = [{"x-a2a-extensions", "#{A2A.extension_uri("1.0")}, #{v091}"}]
    conn = "message/send" |> rpc(user("Hi")) |> post(header) |> call(NarrowAgent)

    assert get_resp_header(conn, "x-a2a-extensions") == [v091]
  end

  test "a body that is not JSON is a parse error" do
    conn = call(post("{not json"), TextAgent)

    assert conn.status == 200
    assert %{"id" => nil, "error" => %{"code" => -32_700}} = json(conn)

    conn = "{}" |> post() |> ClosingAdapter.wrap(read_error: :timeout) |> call(TextAgent)
    assert %{"error" => %{"code" => -32_700}} = json(conn)
  end

  test "refuses a body longer than the limit" do
    conn = call(post(rpc("message/send", user("Hi"))), TextAgent, max_body_length: 16)

    assert conn.status == 413
  end

  test "takes a body that a parser has read already" do
    body = Jason.decode!(rpc("message/send", user("Hi")))
    conn = %{post("") | body_params: body} |> call(TextAgent)

    assert json(conn)["result"]["status"]["message"]["parts"] == [A2A.text_part("You said: Hi")]

    conn = %{post("") | body_params: %{"_json" => [body]}} |> call(TextAgent)
    assert %{"error" => %{"code" => -32_600}} = json(conn)
  end

  test "stops streaming once the client is gone" do
    conn =
      "message/stream"
      |> rpc(user("Hi"))
      |> post()
      |> ClosingAdapter.wrap(chunks: 1)
      |> call(CountingAgent)

    assert [%{"result" => %{"kind" => "task"}}] = SSE.json(conn.resp_body)
    assert_received {:pulled, 1}
    refute_received {:pulled, 2}
  end

  test "serves the agent card on GET" do
    conn = call(conn(:get, "/a2a"), UIAgent)

    assert conn.status == 200
    assert json(conn) == Jason.decode!(Jason.encode!(UIAgent.card()))
  end

  test "allows only the methods it serves" do
    conn = call(conn(:get, "/a2a"), TextAgent)
    assert conn.status == 405
    assert get_resp_header(conn, "allow") == ["POST"]

    conn = call(conn(:delete, "/a2a"), UIAgent)
    assert conn.status == 405
    assert get_resp_header(conn, "allow") == ["GET, POST"]
  end

  test "the test's event-stream reader reads events the way a browser does" do
    body =
      ": a comment\n" <>
        "event: update\nid: 7\ndata: first\ndata\ndata:last\n\n" <>
        "retry: 10\n\n" <>
        "event: ignored\n\n" <>
        "data: {}\r\n\r\n" <>
        "data: unfinished"

    assert SSE.parse(body) == [
             %{event: "update", data: "first\n\nlast"},
             %{event: "message", data: "{}"}
           ]
  end

  test "needs an agent module" do
    for options <- [[], [agent: nil], [agent: "MyAgent"]] do
      assert_raise ArgumentError, ~r/needs an :agent module/, fn -> A2APlug.init(options) end
    end
  end
end

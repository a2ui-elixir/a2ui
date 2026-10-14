defmodule A2UIPhoenix.Plug.SSETest do
  use ExUnit.Case, async: true

  import Plug.Conn
  import Plug.Test

  alias A2UIPhoenix.Plug.SSE
  alias A2UIPhoenix.Test.{ClosingAdapter, Reference}
  alias A2UIPhoenix.Test.SSE, as: Reader

  @create %{
    "version" => "v1.0",
    "createSurface" => %{
      "surfaceId" => "s1",
      "catalogId" => "https://a2ui.org/specification/v1_0/catalogs/basic/catalog.json"
    }
  }
  @update %{
    "version" => "v1.0",
    "updateComponents" => %{
      "surfaceId" => "s1",
      "components" => [%{"id" => "root", "component" => "Text", "text" => "line one\nline two"}]
    }
  }

  # The plug's source: the messages, reporting each one it is asked for.
  def messages(conn, test, messages) do
    send(test, {:source_called, conn.request_path})

    Stream.map(messages, fn message ->
      send(test, {:pulled, message})
      message
    end)
  end

  describe "stream/3" do
    test "sends one event per message, in order" do
      conn = SSE.stream(conn(:get, "/events"), [@create, @update])

      assert conn.status == 200
      assert conn.state == :chunked
      assert get_resp_header(conn, "content-type") == ["text/event-stream; charset=utf-8"]
      assert get_resp_header(conn, "cache-control") == ["no-cache"]
      assert get_resp_header(conn, "x-accel-buffering") == ["no"]

      assert conn.resp_body ==
               "data: #{Jason.encode!(@create)}\n\ndata: #{Jason.encode!(@update)}\n\n"

      assert Reader.json(conn.resp_body) == [@create, @update]
    end

    test "names the events' type" do
      conn = SSE.stream(conn(:get, "/events"), [@create], event: "a2ui")

      assert [%{event: "a2ui", data: data}] = Reader.parse(conn.resp_body)
      assert Jason.decode!(data) == @create
    end

    test "sends JSON text as it is, a data line per line" do
      text = Jason.encode!(@update, pretty: true)
      conn = SSE.stream(conn(:get, "/events"), [text, "{}\r\n"])

      assert conn.resp_body =~ "data: {\ndata:   \"updateComponents\": {\n"
      assert [%{data: ^text}, %{data: "{}\n"}] = Reader.parse(conn.resp_body)
    end

    test "sends an empty stream as no events" do
      conn = SSE.stream(conn(:get, "/events"), [])

      assert conn.state == :chunked
      assert conn.resp_body == ""
    end

    test "stops reading messages once the client is gone" do
      test = self()

      conn =
        :get
        |> conn("/events")
        |> ClosingAdapter.wrap(chunks: 1)
        |> SSE.stream(messages(conn(:get, "/"), test, [@create, @update, @create]))

      assert Reader.json(conn.resp_body) == [@create]
      assert_received {:pulled, @create}
      assert_received {:pulled, @update}
      refute_received {:pulled, _message}
    end

    test "refuses an event type that is not one line" do
      for name <- ["", "two\nlines", "carriage\rreturn"] do
        assert_raise ArgumentError, ~r/one non-empty line/, fn ->
          SSE.stream(conn(:get, "/events"), [@create], event: name)
        end
      end
    end
  end

  describe "as a plug" do
    test "streams what its source returns for the request" do
      options = SSE.init(source: {__MODULE__, :messages, [self(), [@create, @update]]})
      conn = SSE.call(conn(:get, "/a2ui/events"), options)

      assert_received {:source_called, "/a2ui/events"}
      assert Reader.json(conn.resp_body) == [@create, @update]
    end

    test "needs a source" do
      for options <- [[], [source: fn -> [] end], [source: {__MODULE__, :messages, :args}]] do
        assert_raise ArgumentError, ~r/needs a :source/, fn -> SSE.init(options) end
      end
    end
  end

  describe "the transport contract" do
    # Ordered delivery and framing: every example bundle arrives whole,
    # one envelope per event, in the order it was sent.
    test "every example bundle arrives intact and in order" do
      bundles = Reference.bundle_files()
      if Reference.required?(), do: assert(length(bundles) == 86)

      for {_version, file} <- bundles do
        messages = file |> File.read!() |> Jason.decode!() |> Map.fetch!("messages")
        conn = SSE.stream(conn(:get, "/events"), messages)

        assert Reader.json(conn.resp_body) == messages, Path.basename(file)
        assert length(Reader.parse(conn.resp_body)) == length(messages)
      end
    end
  end

  describe "the test's event-stream reader" do
    test "reads events the way a browser does" do
      body =
        ": a comment\n" <>
          "event: update\nid: 7\ndata: first\ndata\ndata:last\n\n" <>
          "retry: 10\n\n" <>
          "event: ignored\n\n" <>
          "data: {}\r\n\r\n" <>
          "data: unfinished"

      assert Reader.parse(body) == [
               %{event: "update", data: "first\n\nlast"},
               %{event: "message", data: "{}"}
             ]
    end
  end
end

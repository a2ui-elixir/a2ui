defmodule A2UIPhoenix.Plug.SSESmokeTest do
  @moduledoc false
  # The event stream over a real HTTP connection (Bandit, read straight
  # off the socket): each message reaches the client before the source
  # produces the next one.

  use ExUnit.Case, async: true

  alias A2UIPhoenix.Test.HTTP
  alias A2UIPhoenix.Test.SSE, as: Reader

  # Yields three messages. Before each one after the first it reports to
  # the test and waits until the test has read what came before.
  def messages(_conn, test) do
    Stream.map(1..3, fn i ->
      if i > 1, do: wait(test, i)
      %{"version" => "v1.0", "deleteSurface" => %{"surfaceId" => "s#{i}"}}
    end)
  end

  defp wait(test, i) do
    send(test, {:waiting, i, self()})

    receive do
      {:go, ^i} -> :ok
    end
  end

  setup do
    server =
      start_supervised!(
        {Bandit,
         plug: {A2UIPhoenix.Plug.SSE, source: {__MODULE__, :messages, [self()]}},
         ip: :loopback,
         port: 0,
         startup_log: false}
      )

    {:ok, {_ip, port}} = ThousandIsland.listener_info(server)
    %{port: port}
  end

  test "sends each message as it happens", %{port: port} do
    {socket, 200, headers} = HTTP.request(port, "GET", "/a2ui/events")
    assert {"content-type", "text/event-stream; charset=utf-8"} in headers
    assert {"transfer-encoding", "chunked"} in headers

    buffer =
      Enum.reduce(2..3, await_events(socket, "", 1), fn i, buffer ->
        assert_receive {:waiting, ^i, source}, 5_000
        send(source, {:go, i})
        await_events(socket, buffer, i)
      end)

    messages = socket |> await_end(buffer) |> Reader.json()
    assert Enum.map(messages, & &1["deleteSurface"]["surfaceId"]) == ["s1", "s2", "s3"]
  end

  defp await_events(socket, buffer, count) do
    if length(Reader.json(buffer)) >= count do
      buffer
    else
      case HTTP.next_chunk(socket) do
        {:ok, data} ->
          await_events(socket, buffer <> data, count)

        other ->
          flunk(
            "expected #{count} events, got: #{inspect(Reader.json(buffer))}, then: #{inspect(other)}"
          )
      end
    end
  end

  defp await_end(socket, buffer) do
    case HTTP.next_chunk(socket) do
      {:ok, data} -> await_end(socket, buffer <> data)
      :done -> buffer
      other -> flunk("the stream did not end: #{inspect(other)}")
    end
  end
end

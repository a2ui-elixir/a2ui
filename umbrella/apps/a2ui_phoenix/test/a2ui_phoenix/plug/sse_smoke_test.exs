defmodule A2UIPhoenix.Plug.SSESmokeTest do
  @moduledoc false
  # The event stream over a real HTTP connection (Bandit, read with OTP's
  # :httpc): each message reaches the client before the source produces
  # the next one.

  use ExUnit.Case, async: true

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
    {:ok, _apps} = Application.ensure_all_started(:inets)

    server =
      start_supervised!(
        {Bandit,
         plug: {A2UIPhoenix.Plug.SSE, source: {__MODULE__, :messages, [self()]}},
         ip: :loopback,
         port: 0,
         startup_log: false}
      )

    {:ok, {_ip, port}} = ThousandIsland.listener_info(server)
    %{url: ~c"http://127.0.0.1:#{port}/a2ui/events"}
  end

  test "sends each message as it happens", %{url: url} do
    {:ok, ref} = :httpc.request(:get, {url, []}, [], sync: false, stream: :self)

    assert_receive {:http, {^ref, :stream_start, headers}}, 5_000
    assert {~c"content-type", ~c"text/event-stream; charset=utf-8"} in headers

    buffer =
      Enum.reduce(2..3, await_events(ref, "", 1), fn i, buffer ->
        assert_receive {:waiting, ^i, source}, 5_000
        send(source, {:go, i})
        await_events(ref, buffer, i)
      end)

    messages = ref |> await_end(buffer) |> Reader.json()
    assert Enum.map(messages, & &1["deleteSurface"]["surfaceId"]) == ["s1", "s2", "s3"]
  end

  defp await_events(ref, buffer, count) do
    if length(Reader.json(buffer)) >= count do
      buffer
    else
      receive do
        {:http, {^ref, :stream, chunk}} -> await_events(ref, buffer <> chunk, count)
      after
        5_000 -> flunk("expected #{count} events, got: #{inspect(Reader.json(buffer))}")
      end
    end
  end

  defp await_end(ref, buffer) do
    receive do
      {:http, {^ref, :stream, chunk}} -> await_end(ref, buffer <> chunk)
      {:http, {^ref, :stream_end, _headers}} -> buffer
    after
      5_000 -> flunk("the stream did not end")
    end
  end
end

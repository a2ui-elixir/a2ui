defmodule A2UIAgent.A2A.PlugSmokeTest do
  @moduledoc false
  # `message/stream` over a real HTTP connection (Bandit, read with OTP's
  # :httpc): every event reaches the client before the agent produces the
  # next chunk.

  use ExUnit.Case, async: true

  alias A2UIAgent.A2A
  alias A2UIAgent.Test.SSE

  # Writes three chunks. Before each one after the first it reports to
  # the test and waits until the test has read what came before.
  defmodule SteppedAgent do
    @behaviour A2UIAgent.A2A.Agent

    @impl true
    def run(request) do
      test =
        request.message["metadata"]["testPid"]
        |> String.to_charlist()
        |> :erlang.list_to_pid()

      {:ok, Stream.map(1..3, &step(&1, test))}
    end

    defp step(1, _test), do: "one."

    defp step(i, test) do
      send(test, {:waiting, i, self()})

      receive do
        {:go, ^i} -> " step #{i}."
      end
    end
  end

  setup do
    {:ok, _apps} = Application.ensure_all_started(:inets)

    server =
      start_supervised!(
        {Bandit,
         plug: {A2UIAgent.A2A.Plug, agent: SteppedAgent},
         ip: :loopback,
         port: 0,
         startup_log: false}
      )

    {:ok, {_ip, port}} = ThousandIsland.listener_info(server)
    %{url: ~c"http://127.0.0.1:#{port}/a2a"}
  end

  test "streams each event as it happens", %{url: url} do
    message = %{
      "role" => "user",
      "parts" => [A2A.text_part("Hi")],
      "metadata" => %{"testPid" => List.to_string(:erlang.pid_to_list(self()))}
    }

    body =
      Jason.encode!(%{
        "jsonrpc" => "2.0",
        "id" => "smoke",
        "method" => "message/stream",
        "params" => %{"message" => message}
      })

    {:ok, ref} =
      :httpc.request(:post, {url, [], ~c"application/json", body}, [], sync: false, stream: :self)

    assert_receive {:http, {^ref, :stream_start, headers}}, 5_000
    assert {~c"content-type", ~c"text/event-stream; charset=utf-8"} in headers

    buffer = await_events(ref, "", 2)
    assert_receive {:waiting, 2, agent}, 5_000
    send(agent, {:go, 2})

    buffer = await_events(ref, buffer, 3)
    assert_receive {:waiting, 3, agent}, 5_000
    send(agent, {:go, 3})

    results = ref |> await_end(buffer) |> SSE.json() |> Enum.map(& &1["result"])

    assert [%{"kind" => "task"} | _] = results
    assert %{"final" => true, "status" => %{"state" => "input-required"}} = List.last(results)

    texts =
      for %{"status" => %{"state" => "working", "message" => %{"parts" => parts}}} <- results,
          %{"text" => text} <- parts,
          do: text

    assert texts == ["one.", " step 2.", " step 3."]
  end

  defp await_events(ref, buffer, count) do
    if length(SSE.json(buffer)) >= count do
      buffer
    else
      receive do
        {:http, {^ref, :stream, chunk}} -> await_events(ref, buffer <> chunk, count)
      after
        5_000 -> flunk("expected #{count} events, got: #{inspect(SSE.json(buffer))}")
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

defmodule A2UIAgent.A2A.PlugSmokeTest do
  @moduledoc false
  # `message/stream` over a real HTTP connection (Bandit, read straight
  # off the socket): every event reaches the client before the agent
  # produces the next chunk.

  use ExUnit.Case, async: true

  alias A2UIAgent.A2A
  alias A2UIAgent.Test.HTTP
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
    server =
      start_supervised!(
        {Bandit,
         plug: {A2UIAgent.A2A.Plug, agent: SteppedAgent},
         ip: :loopback,
         port: 0,
         startup_log: false}
      )

    {:ok, {_ip, port}} = ThousandIsland.listener_info(server)
    %{port: port}
  end

  test "streams each event as it happens", %{port: port} do
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

    {socket, 200, headers} =
      HTTP.request(port, "POST", "/a2a", [{"content-type", "application/json"}], body)

    assert {"content-type", "text/event-stream; charset=utf-8"} in headers
    assert {"transfer-encoding", "chunked"} in headers

    buffer = await_events(socket, "", 2)
    assert_receive {:waiting, 2, agent}, 5_000
    send(agent, {:go, 2})

    buffer = await_events(socket, buffer, 3)
    assert_receive {:waiting, 3, agent}, 5_000
    send(agent, {:go, 3})

    results = socket |> await_end(buffer) |> SSE.json() |> Enum.map(& &1["result"])

    assert [%{"kind" => "task"} | _] = results
    assert %{"final" => true, "status" => %{"state" => "input-required"}} = List.last(results)

    texts =
      for %{"status" => %{"state" => "working", "message" => %{"parts" => parts}}} <- results,
          %{"text" => text} <- parts,
          do: text

    assert texts == ["one.", " step 2.", " step 3."]
  end

  defp await_events(socket, buffer, count) do
    if length(SSE.json(buffer)) >= count do
      buffer
    else
      case HTTP.next_chunk(socket) do
        {:ok, data} ->
          await_events(socket, buffer <> data, count)

        other ->
          flunk(
            "expected #{count} events, got: #{inspect(SSE.json(buffer))}, then: #{inspect(other)}"
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

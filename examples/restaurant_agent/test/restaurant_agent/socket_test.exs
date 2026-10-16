defmodule RestaurantAgent.SocketTest do
  # The WebSocket endpoint, over a real connection.
  use ExUnit.Case, async: true

  import RestaurantAgent.Test.A2A, only: [capabilities: 1, keys: 1]

  setup do
    {:ok, server} =
      start_supervised(
        {Bandit, plug: RestaurantAgent.Router, ip: {127, 0, 0, 1}, port: 0, startup_log: false}
      )

    {:ok, {_ip, port}} = ThousandIsland.listener_info(server)
    {:ok, conn} = Mint.HTTP.connect(:http, "127.0.0.1", port, protocols: [:http1])
    {:ok, conn, ref} = Mint.WebSocket.upgrade(:ws, conn, "/ws", [])
    {conn, ref, websocket} = await_upgrade(conn, ref)
    %{socket: %{conn: conn, ref: ref, websocket: websocket, buffer: []}}
  end

  defp await_upgrade(conn, ref) do
    message = receive(do: (message -> message))
    {:ok, conn, responses} = Mint.WebSocket.stream(conn, message)
    {:status, ^ref, status} = List.keyfind(responses, :status, 0)
    {:headers, ^ref, headers} = List.keyfind(responses, :headers, 0)
    assert status == 101
    {:ok, conn, websocket} = Mint.WebSocket.new(conn, ref, status, headers)
    {conn, ref, websocket}
  end

  defp push(socket, value) do
    {:ok, websocket, data} =
      Mint.WebSocket.encode(socket.websocket, {:text, Jason.encode!(value)})

    {:ok, conn} = Mint.WebSocket.stream_request_body(socket.conn, socket.ref, data)
    %{socket | conn: conn, websocket: websocket}
  end

  # Frames until one matches `stop?`.
  defp frames(socket, stop?, acc \\ []) do
    case Enum.split_while(socket.buffer, &(not stop?.(&1))) do
      {before, [last | rest]} ->
        {acc ++ before ++ [last], %{socket | buffer: rest}}

      {all, []} ->
        message = receive(do: (message -> message), after: (2_000 -> flunk("no frame")))
        {:ok, conn, [{:data, _ref, data}]} = Mint.WebSocket.stream(socket.conn, message)
        {:ok, websocket, decoded} = Mint.WebSocket.decode(socket.websocket, data)
        values = for {:text, text} <- decoded, do: Jason.decode!(text)
        frames(%{socket | conn: conn, websocket: websocket, buffer: values}, stop?, acc ++ all)
    end
  end

  defp turn(socket, value), do: socket |> push(value) |> frames(&Map.has_key?(&1, "done"))

  test "a session: capabilities, text, then function calls", %{socket: socket} do
    {[%{"ready" => true}], socket} =
      socket |> push(%{"metadata" => capabilities(:v1)}) |> frames(& &1["ready"])

    {frames, socket} = turn(socket, %{"text" => "Find Mexican food"})

    assert [%{"text" => "Here is one place." <> _}, %{"createSurface" => _}, %{"done" => true}] =
             frames

    call = %{
      "version" => "v1.0",
      "callAgentFunction" => %{
        "surfaceId" => "booking-1",
        "functionCallId" => "call-1",
        "callFunction" => %{
          "@call" => "checkAvailability",
          "args" => %{"restaurantId" => "la-cantina", "date" => "2026-10-18", "partySize" => 2}
        }
      }
    }

    {frames, socket} = turn(socket, %{"message" => call})

    assert [
             %{
               "agentFunctionResponse" => %{
                 "functionCallId" => "call-1",
                 "value" => "A table for 2" <> _
               }
             },
             %{"done" => true}
           ] = frames

    {[%{"error" => _}], socket} =
      socket |> push(%{"hello" => 1}) |> frames(&Map.has_key?(&1, "error"))

    {[%{"error" => _}, %{"done" => true}], _socket} =
      turn(socket, %{
        "text" => "x",
        "metadata" => %{
          "a2uiRendererCapabilities" => %{"v1.0" => %{"supportedCatalogIds" => ["nope"]}}
        }
      })
  end

  test "v0.9 renderers get v0.9 messages", %{socket: socket} do
    {frames, _socket} =
      turn(socket, %{
        "text" => "french",
        "metadata" =>
          capabilities(:v09) |> Map.new(fn {_k, v} -> {"a2uiRendererCapabilities", v} end)
      })

    assert keys(Enum.filter(frames, &Map.has_key?(&1, "version"))) == [
             "createSurface",
             "updateComponents",
             "updateDataModel"
           ]
  end
end

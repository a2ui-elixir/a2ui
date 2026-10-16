defmodule TerminalClient.Transports.WebSocket do
  @moduledoc """
  A WebSocket session (`Mint.WebSocket`): every frame one JSON object.
  The renderer's capabilities go first; then each text or renderer
  message is a frame, answered by the agent's frames up to
  `{"done": true}`. Everything travels both ways, function calls too.
  """

  @behaviour TerminalClient.Transport

  @impl true
  def connect(url, _options) do
    uri = URI.parse(url)
    scheme = if uri.scheme == "wss", do: :https, else: :http

    with {:ok, conn} <- Mint.HTTP.connect(scheme, uri.host, uri.port, protocols: [:http1]),
         {:ok, conn, ref} <-
           Mint.WebSocket.upgrade(
             if(scheme == :https, do: :wss, else: :ws),
             conn,
             uri.path || "/",
             []
           ),
         {:ok, conn, websocket} <- await_upgrade(conn, ref) do
      {:ok, %{conn: conn, ref: ref, websocket: websocket, buffer: []}}
    end
  end

  defp await_upgrade(conn, ref) do
    socket = Mint.HTTP.get_socket(conn)

    receive do
      message when elem(message, 1) == socket ->
        with {:ok, conn, responses} <- Mint.WebSocket.stream(conn, message),
             {:status, ^ref, status} <- List.keyfind(responses, :status, 0),
             {:headers, ^ref, headers} <- List.keyfind(responses, :headers, 0),
             {:ok, conn, websocket} <- Mint.WebSocket.new(conn, ref, status, headers) do
          {:ok, conn, websocket}
        else
          _failed -> {:error, "The WebSocket upgrade failed."}
        end
    after
      5_000 -> {:error, "The agent did not answer the WebSocket upgrade."}
    end
  end

  @impl true
  def supports?(_message), do: true

  @impl true
  def request(state, inputs, metadata, on_output) do
    Enum.reduce_while(inputs, {:ok, state, []}, fn input, {:ok, state, outputs} ->
      frame =
        case input do
          {:text, text} -> %{"text" => text, "metadata" => metadata}
          {:message, message} -> %{"message" => message, "metadata" => metadata}
        end

      with {:ok, state} <- push(state, frame),
           {:ok, state, frames} <- until_done(state, []) do
        found = Enum.flat_map(frames, &output/1)
        Enum.each(found, on_output)
        {:cont, {:ok, state, outputs ++ found}}
      else
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp output(%{"text" => text}), do: [{:text, text}]
  defp output(%{"error" => error}), do: [{:text, "error: #{error}"}]
  defp output(%{"version" => _} = message), do: [{:a2ui, [message]}]
  defp output(_other), do: []

  defp push(state, value) do
    with {:ok, websocket, data} <-
           Mint.WebSocket.encode(state.websocket, {:text, Jason.encode!(value)}),
         {:ok, conn} <- Mint.WebSocket.stream_request_body(state.conn, state.ref, data) do
      {:ok, %{state | conn: conn, websocket: websocket}}
    end
  end

  defp until_done(%{buffer: [%{"done" => true} | rest]} = state, frames),
    do: {:ok, %{state | buffer: rest}, frames}

  defp until_done(%{buffer: [frame | rest]} = state, frames),
    do: until_done(%{state | buffer: rest}, frames ++ [frame])

  # Only the socket's own messages: anything else in the mailbox stays.
  defp until_done(%{buffer: []} = state, frames) do
    socket = Mint.HTTP.get_socket(state.conn)

    receive do
      message when elem(message, 1) == socket ->
        case Mint.WebSocket.stream(state.conn, message) do
          {:ok, conn, responses} ->
            {websocket, values} = decode(state.websocket, responses)
            until_done(%{state | conn: conn, websocket: websocket, buffer: values}, frames)

          {:error, _conn, error, _responses} ->
            {:error, Exception.message(error)}

          :unknown ->
            until_done(state, frames)
        end
    after
      30_000 -> {:error, "The agent stopped answering."}
    end
  end

  defp decode(websocket, responses) do
    Enum.reduce(responses, {websocket, []}, fn
      {:data, _ref, data}, {websocket, values} ->
        {:ok, websocket, decoded} = Mint.WebSocket.decode(websocket, data)
        {websocket, values ++ for({:text, text} <- decoded, do: Jason.decode!(text))}

      _other, acc ->
        acc
    end)
  end
end

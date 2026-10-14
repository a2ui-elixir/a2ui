defmodule A2UIPhoenix.Test.HTTP do
  @moduledoc false
  # A bare HTTP/1.1 client over :gen_tcp that reads a chunked response
  # chunk by chunk, each as soon as it arrives. OTP's :httpc can't be
  # relied on for that: body data it reads together with the headers stays
  # in its buffer until more data comes, and a stream that waits for its
  # reader sends none.

  @timeout 5_000

  # Sends the request, then reads the status line and the headers (names
  # in lower case).
  def request(port, method, path, headers \\ [], body \\ "") do
    {:ok, socket} =
      :gen_tcp.connect({127, 0, 0, 1}, port, [:binary, active: false, packet: :http_bin])

    length = if body == "", do: [], else: [{"content-length", byte_size(body)}]

    lines =
      for {name, value} <- [{"host", "127.0.0.1:#{port}"} | length ++ headers],
          do: [name, ": ", to_string(value), "\r\n"]

    :ok = :gen_tcp.send(socket, [method, " ", path, " HTTP/1.1\r\n", lines, "\r\n", body])
    {:ok, {:http_response, _version, status, _reason}} = :gen_tcp.recv(socket, 0, @timeout)
    {socket, status, read_headers(socket, [])}
  end

  # The data of the next chunk, `:done` after the last one, or what went
  # wrong (`{:error, :timeout}`, say).
  def next_chunk(socket) do
    :ok = :inet.setopts(socket, packet: :line)

    with {:ok, line} <- :gen_tcp.recv(socket, 0, @timeout),
         {size, _extensions} <- Integer.parse(line, 16),
         :ok <- :inet.setopts(socket, packet: :raw),
         {:ok, <<data::binary-size(^size), "\r\n">>} <- :gen_tcp.recv(socket, size + 2, @timeout) do
      if size == 0, do: :done, else: {:ok, data}
    end
  end

  defp read_headers(socket, headers) do
    case :gen_tcp.recv(socket, 0, @timeout) do
      {:ok, {:http_header, _, name, _, value}} ->
        read_headers(socket, [{String.downcase(to_string(name)), value} | headers])

      {:ok, :http_eoh} ->
        Enum.reverse(headers)
    end
  end
end

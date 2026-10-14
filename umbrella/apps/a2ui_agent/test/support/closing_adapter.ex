defmodule A2UIAgent.Test.ClosingAdapter do
  @moduledoc false
  # Plug.Test's adapter, except that the client goes away after a number
  # of chunks (`chunks:`) or the request body cannot be read
  # (`read_error:`).

  alias Plug.Adapters.Test.Conn, as: TestConn

  def wrap(%Plug.Conn{adapter: {TestConn, state}} = conn, options) do
    payload = %{
      state: state,
      chunks: Keyword.get(options, :chunks, :infinity),
      read_error: options[:read_error]
    }

    %{conn | adapter: {__MODULE__, payload}}
  end

  def send_resp(payload, status, headers, body) do
    {:ok, body, state} = TestConn.send_resp(payload.state, status, headers, body)
    {:ok, body, %{payload | state: state}}
  end

  def send_chunked(payload, status, headers) do
    {:ok, body, state} = TestConn.send_chunked(payload.state, status, headers)
    {:ok, body, %{payload | state: state}}
  end

  def chunk(%{chunks: 0}, _body), do: {:error, :closed}

  def chunk(payload, body) do
    {:ok, body, state} = TestConn.chunk(payload.state, body)
    left = if payload.chunks == :infinity, do: :infinity, else: payload.chunks - 1
    {:ok, body, %{payload | state: state, chunks: left}}
  end

  def read_req_body(%{read_error: nil} = payload, options) do
    {status, body, state} = TestConn.read_req_body(payload.state, options)
    {status, body, %{payload | state: state}}
  end

  def read_req_body(%{read_error: reason}, _options), do: {:error, reason}
end

defmodule A2UIPhoenix.Plug.SSE do
  @moduledoc """
  Streams A2UI messages to a renderer outside LiveView as
  [server-sent events](https://html.spec.whatwg.org/multipage/server-sent-events.html).

  Each message is one event whose data is the message's JSON, sent as
  soon as the enumerable yields it, in order:

      data: {"version":"v1.0","createSurface":{"surfaceId":"s1","catalogId":"…"}}

      data: {"version":"v1.0","updateComponents":{"surfaceId":"s1","components":[…]}}

  From a controller:

      def events(conn, params), do: A2UIPhoenix.Plug.SSE.stream(conn, MyAgent.messages(params))

  or mounted, with a source that is called with the conn (and any further
  arguments) on each request:

      forward "/a2ui/events", A2UIPhoenix.Plug.SSE, source: {MyAgent, :messages, []}

  The enumerable is consumed lazily, and no further once the client has
  gone. The response ends when the enumerable does; since an
  `EventSource` reconnects when a response ends, a client using one
  closes it once its stream is complete.

  ## Resuming a stream

  A message given as `{id, message}` is sent with an `id:` line. A
  browser's `EventSource` that loses the connection reconnects and sends
  the last id it received in the `Last-Event-ID` header, which
  `last_event_id/1` reads, so the source can continue after it:

      def messages(conn) do
        after_id = A2UIPhoenix.Plug.SSE.last_event_id(conn)
        MyAgent.messages_since(after_id) |> Stream.map(&{&1.seq, &1.message})
      end

  The `:retry` option tells the client how long to wait before it
  reconnects.

  Options:

    * `:source` — for the plug, `{module, function, args}`: called as
      `apply(module, function, [conn | args])`, it returns the
      enumerable of messages.
    * `:event` — the event type of every message (default: none, which a
      browser delivers as a `message` event).
    * `:retry` — the reconnection delay in milliseconds, sent first.
  """

  @behaviour Plug

  import Plug.Conn

  @moduledoc since: "0.1.0"

  @impl Plug
  def init(options) do
    case Keyword.get(options, :source) do
      {module, function, args} when is_atom(module) and is_atom(function) and is_list(args) ->
        options

      other ->
        raise ArgumentError,
              "A2UIPhoenix.Plug.SSE needs a :source {module, function, args}, got: " <>
                inspect(other)
    end
  end

  @impl Plug
  def call(conn, options) do
    {module, function, args} = Keyword.fetch!(options, :source)
    stream(conn, apply(module, function, [conn | args]), options)
  end

  @doc """
  Sends `messages` as an event stream and returns the conn.

  A message is a map (or list) to encode as JSON, or JSON text already
  encoded; text that spans lines is sent as one data line per line, as
  the event stream format requires. A `{id, message}` pair is sent with
  its id. Options: `:event` and `:retry`.
  """
  @spec stream(Plug.Conn.t(), Enumerable.t(), keyword()) :: Plug.Conn.t()
  def stream(%Plug.Conn{} = conn, messages, options \\ []) do
    retry = retry_line(options[:retry])

    conn =
      conn
      |> put_resp_content_type("text/event-stream")
      |> put_resp_header("cache-control", "no-cache")
      |> put_resp_header("x-accel-buffering", "no")
      |> send_chunked(200)

    case if(retry == [], do: {:ok, conn}, else: chunk(conn, retry)) do
      {:ok, conn} -> send_events(conn, messages, options)
      {:error, _reason} -> conn
    end
  end

  defp send_events(conn, messages, options) do
    Enum.reduce_while(messages, conn, fn message, conn ->
      case chunk(conn, event(message, options)) do
        {:ok, conn} -> {:cont, conn}
        {:error, _reason} -> {:halt, conn}
      end
    end)
  end

  @doc """
  One event of the stream: its `event:` line if the `:event` option is
  given, its `id:` line for a `{id, message}` pair, its data lines and
  the blank line that ends it.
  """
  @spec event(map() | list() | String.t() | {String.t() | integer(), term()}, keyword()) ::
          iodata()
  def event(message, options \\ [])

  def event({id, message}, options),
    do: [event_line(options[:event]), id_line(id), data_lines(message), ?\n]

  def event(message, options), do: [event_line(options[:event]), data_lines(message), ?\n]

  @doc """
  The id of the last event a reconnecting client received (its
  `Last-Event-ID` header), or `nil`.
  """
  @spec last_event_id(Plug.Conn.t()) :: String.t() | nil
  def last_event_id(%Plug.Conn{} = conn) do
    case get_req_header(conn, "last-event-id") do
      [id | _] -> id
      [] -> nil
    end
  end

  defp id_line(id) when is_integer(id), do: ["id: ", Integer.to_string(id), ?\n]

  defp id_line(id) when is_binary(id) do
    if String.contains?(id, ["\r", "\n", <<0>>]) do
      raise ArgumentError, "an event id is one line without NUL, got: #{inspect(id)}"
    end

    ["id: ", id, ?\n]
  end

  defp retry_line(nil), do: []

  defp retry_line(ms) when is_integer(ms) and ms >= 0,
    do: ["retry: ", Integer.to_string(ms), "\n\n"]

  defp retry_line(other),
    do: raise(ArgumentError, "retry is a number of milliseconds, got: #{inspect(other)}")

  defp event_line(nil), do: []

  defp event_line(name) when is_binary(name) do
    if name == "" or String.contains?(name, ["\r", "\n"]) do
      raise ArgumentError, "an event type is one non-empty line, got: #{inspect(name)}"
    end

    ["event: ", name, ?\n]
  end

  defp data_lines(text) when is_binary(text),
    do: for(line <- String.split(text, ~r/\r\n|\r|\n/), do: ["data: ", line, ?\n])

  defp data_lines(message), do: ["data: ", Jason.encode_to_iodata!(message), ?\n]
end

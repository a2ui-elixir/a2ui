if Code.ensure_loaded?(Plug.Conn) do
  defmodule A2UIAgent.A2A.Plug do
    @moduledoc """
    Serves an agent over A2A's JSON-RPC binding with
    `A2UIAgent.A2A.Server`.

        forward "/a2a", A2UIAgent.A2A.Plug, agent: MyAgent

    `MyAgent` implements `A2UIAgent.A2A.Agent`. A `POST` carries a
    JSON-RPC request: `message/send` is answered with JSON and
    `message/stream` with server-sent events, one JSON-RPC response per
    event. A body that is not JSON gets a JSON-RPC parse error (-32700).
    A `GET` returns the agent's card, when it has one.

    The `X-A2A-Extensions` request header lists the extensions the client
    requests. The A2UI extension activated for the request, which must be
    one the agent's card advertises, is listed in the same response
    header.

    The body is read as JSON unless a `Plug.Parsers` before this plug has
    already parsed it. This module needs the optional `plug` dependency.

    Options: `:agent` (required); `:max_body_length` in bytes (default
    8,000,000; a longer body gets status 413).
    """

    @behaviour Plug

    import Plug.Conn

    alias A2UIAgent.A2A
    alias A2UIAgent.A2A.Server

    @moduledoc since: "0.1.0"

    @default_max_body_length 8_000_000

    @impl Plug
    def init(options) do
      case Keyword.get(options, :agent) do
        agent when is_atom(agent) and not is_nil(agent) ->
          options

        other ->
          raise ArgumentError,
                "A2UIAgent.A2A.Plug needs an :agent module, got: #{inspect(other)}"
      end
    end

    @impl Plug
    def call(%Plug.Conn{method: "POST"} = conn, options) do
      agent = Keyword.fetch!(options, :agent)
      Code.ensure_loaded(agent)

      case read_json(conn, Keyword.get(options, :max_body_length, @default_max_body_length)) do
        {:ok, body, conn} ->
          answer(conn, Server.handle(body, agent, server_options(conn, agent)))

        {:error, :invalid_json, conn} ->
          send_json(
            conn,
            Server.error_response(nil, -32_700, "Parse error: the body is not JSON.")
          )

        {:error, :too_large, conn} ->
          send_resp(conn, 413, "")
      end
    end

    def call(%Plug.Conn{method: "GET"} = conn, options) do
      agent = Keyword.fetch!(options, :agent)

      if card?(agent),
        do: send_json(conn, agent.card()),
        else: not_allowed(conn, agent)
    end

    def call(conn, options), do: not_allowed(conn, Keyword.fetch!(options, :agent))

    defp card?(agent), do: Code.ensure_loaded?(agent) and function_exported?(agent, :card, 0)

    defp not_allowed(conn, agent) do
      conn
      |> put_resp_header("allow", if(card?(agent), do: "GET, POST", else: "POST"))
      |> send_resp(405, "")
    end

    defp read_json(%Plug.Conn{body_params: params} = conn, max_length)
         when params == %{} or is_struct(params, Plug.Conn.Unfetched) do
      case read_body(conn, length: max_length) do
        {:ok, body, conn} -> decode(body, conn)
        {:more, _partial, conn} -> {:error, :too_large, conn}
        {:error, _reason} -> {:error, :invalid_json, conn}
      end
    end

    defp read_json(%Plug.Conn{body_params: %{"_json" => json} = params} = conn, _max_length)
         when map_size(params) == 1,
         do: {:ok, json, conn}

    defp read_json(%Plug.Conn{body_params: params} = conn, _max_length), do: {:ok, params, conn}

    defp decode(body, conn) do
      case Jason.decode(body) do
        {:ok, json} -> {:ok, json, conn}
        {:error, _error} -> {:error, :invalid_json, conn}
      end
    end

    defp server_options(conn, agent) do
      options = if function_exported?(agent, :options, 0), do: agent.options(), else: []
      advertised = if card?(agent), do: A2A.advertised_extensions(agent.card()), else: []

      options
      |> Keyword.put_new(:advertised, advertised)
      |> Keyword.put(:extensions, get_req_header(conn, "x-a2a-extensions"))
    end

    defp answer(conn, {:reply, response, extensions}),
      do: conn |> put_extensions(extensions) |> send_json(response)

    defp answer(conn, {:stream, events, extensions}),
      do: conn |> put_extensions(extensions) |> send_events(events)

    defp put_extensions(conn, []), do: conn

    defp put_extensions(conn, uris),
      do: put_resp_header(conn, "x-a2a-extensions", Enum.join(uris, ", "))

    defp send_json(conn, value) do
      conn
      |> put_resp_content_type("application/json")
      |> send_resp(200, Jason.encode_to_iodata!(value))
    end

    defp send_events(conn, events) do
      conn =
        conn
        |> put_resp_content_type("text/event-stream")
        |> put_resp_header("cache-control", "no-cache")
        |> put_resp_header("x-accel-buffering", "no")
        |> send_chunked(200)

      Enum.reduce_while(events, conn, fn event, conn ->
        case chunk(conn, ["data: ", Jason.encode_to_iodata!(event), "\n\n"]) do
          {:ok, conn} -> {:cont, conn}
          {:error, _closed} -> {:halt, conn}
        end
      end)
    end
  end
end

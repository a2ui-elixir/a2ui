defmodule RestaurantAgent.Router do
  @moduledoc """
  The agent's HTTP endpoints; see `RestaurantAgent` for what each one
  serves. `GET /prompt` shows the system prompt the agent would give a
  model (`?version=v0.9`, `?format=express`).
  """

  use Plug.Router

  alias A2UIAgent.{Generator, RequestProcessor}
  alias RestaurantAgent.{Agent, AGUIServer, Catalogs, ExpressAgent, MCPServer, Restaurants, Turns}

  plug(Plug.Logger)
  plug(:match)
  plug(Plug.Parsers, parsers: [:json], pass: ["*/*"], json_decoder: Jason)
  plug(:dispatch)

  get "/" do
    send_resp(conn, 200, "Restaurant finder agent. See /.well-known/agent-card.json.")
  end

  get("/healthz", do: send_resp(conn, 200, "ok"))

  get("/.well-known/agent-card.json", do: json(conn, Agent.card()))

  get "/prompt" do
    conn = fetch_query_params(conn)
    express? = conn.query_params["format"] == "express"
    format = if express?, do: A2UIAgent.Express, else: A2UIAgent.DirectJson

    capabilities =
      if conn.query_params["version"] == "v0.9",
        do: %{"v0.9" => %{"supportedCatalogIds" => [Catalogs.basic("v0.9.1").catalog_id]}},
        else: Turns.default_capabilities()

    [v1, v09] = Catalogs.generators(format: format)
    generator = if Map.has_key?(capabilities, "v0.9"), do: v09, else: v1

    {:ok, processor} = Generator.create_processor(generator, capabilities)
    {:ok, prompt} = RequestProcessor.prompt(processor)

    conn |> put_resp_content_type("text/plain") |> send_resp(200, prompt)
  end

  get "/images/:file" do
    with id <- Path.rootname(file),
         svg when is_binary(svg) <- Restaurants.image(id) do
      conn |> put_resp_content_type("image/svg+xml") |> send_resp(200, svg)
    else
      _missing -> send_resp(conn, 404, "")
    end
  end

  forward("/a2a/express", to: A2UIAgent.A2A.Plug, init_opts: [agent: ExpressAgent])
  forward("/a2a", to: A2UIAgent.A2A.Plug, init_opts: [agent: Agent])

  post "/mcp" do
    case MCPServer.handle(conn.body_params) do
      nil -> send_resp(conn, 202, "")
      response -> json(conn, response)
    end
  end

  post "/agui" do
    events = AGUIServer.run(conn.body_params)

    conn =
      conn
      |> put_resp_content_type("text/event-stream")
      |> put_resp_header("cache-control", "no-cache")
      |> send_chunked(200)

    Enum.reduce_while(events, conn, fn event, conn ->
      case chunk(conn, A2UIAgent.AGUI.encode(event)) do
        {:ok, conn} -> {:cont, conn}
        {:error, _closed} -> {:halt, conn}
      end
    end)
  end

  get "/events" do
    conn = fetch_query_params(conn)
    version = conn.query_params["version"]

    capabilities =
      if version == "v0.9",
        do: %{"v0.9" => %{"supportedCatalogIds" => [Catalogs.basic("v0.9.1").catalog_id]}},
        else: nil

    case Turns.answer(conn.query_params["q"] || "", [], capabilities,
           turn_id: "sse",
           function_calls: false
         ) do
      {:ok, answer} ->
        after_id = A2UIPhoenix.Plug.SSE.last_event_id(conn)
        delay = Application.get_env(:restaurant_agent, :chunk_delay_ms, 0)

        events =
          answer.messages
          |> Enum.with_index(1)
          |> Enum.map(fn {message, index} -> {Integer.to_string(index), message} end)
          |> Enum.drop_while(fn {id, _message} -> after_id != nil and id != after_id end)
          |> Enum.drop(if(after_id, do: 1, else: 0))
          |> Stream.each(fn _event -> if delay > 0, do: Process.sleep(delay * 4) end)

        A2UIPhoenix.Plug.SSE.stream(conn, events, retry: 2_000)

      {:error, reason} ->
        send_resp(conn, 400, reason)
    end
  end

  get "/ws" do
    conn
    |> WebSockAdapter.upgrade(RestaurantAgent.Socket, [], timeout: 300_000)
    |> halt()
  end

  match(_, do: send_resp(conn, 404, "Not found"))

  defp json(conn, value) do
    conn |> put_resp_content_type("application/json") |> send_resp(200, Jason.encode!(value))
  end
end

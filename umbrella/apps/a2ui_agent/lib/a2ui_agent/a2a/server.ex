defmodule A2UIAgent.A2A.Server do
  @moduledoc """
  Answers the A2A JSON-RPC methods `message/send` and `message/stream`
  for an agent that writes A2UI.

      case A2UIAgent.A2A.Server.handle(body, &MyAgent.run/1, generator: generator) do
        {:reply, response, extensions} -> # send the response as JSON
        {:stream, events, extensions} -> # send each event as a server-sent event
      end

  `extensions` lists the extension URIs activated for the request, for
  the `X-A2A-Extensions` response header. `A2UIAgent.A2A.Plug` does all
  of this over HTTP.

  ## The agent

  The agent is a function of an `A2UIAgent.A2A.Request`, or a module
  implementing `A2UIAgent.A2A.Agent`. It returns:

    * `{:ok, output}` or `{:ok, output, state}` — the model's response,
      as a string or an enumerable of streamed chunks, and the state the
      task ends in (`"input-required"` unless the `:final_state` option
      says otherwise);
    * `{:error, reason}` — the task fails, with `reason` as its status
      message.

  ## Requests and answers

  The server reads the message into an `A2UIAgent.A2A.Request` and
  negotiates catalogs for the renderer. Given a generator and renderer
  capabilities (from the message metadata, else the
  `:default_capabilities` option), the request carries an
  `A2UIAgent.RequestProcessor`: the agent gives its prompt to the model,
  and its parser reads the model's output into a text part for each run
  of text and an A2UI data part for each message. Without a processor
  the output is answered as text. Capabilities that name none of the
  agent's catalogs fail the task.

  `message/send` answers with the finished task, whose status message
  holds every part. A response that does not parse is answered as text.
  `message/stream` answers with a stream of JSON-RPC responses: the
  task (`submitted`), a `working` status update for each chunk that
  completes parts, and a final status update. A stream that stops
  parsing fails the task.

  ## Options

    * `:generator` — an `A2UIAgent.Generator`, or a list of them (one per
      protocol version, in order of preference; the first that
      negotiates wins).
    * `:default_capabilities` — the capabilities to negotiate when the
      message carries none.
    * `:extensions` — the extension URIs the client requested in the
      `X-A2A-Extensions` header.
    * `:advertised` — the A2UI extension URIs the agent advertises
      (`A2UIAgent.A2A.advertised_extensions/1` of its agent card).
    * `:final_state` — the state a task ends in (default
      `"input-required"`).
    * `:id_generator` — a zero-arity function that returns new task,
      context and message ids (default: random UUIDs).
    * `:clock` — a zero-arity function that returns the ISO 8601
      timestamp of a task status (default: the current time).
  """

  alias A2UIAgent.{A2A, Catalogs, Generator, RequestProcessor}
  alias A2UIAgent.A2A.Request

  @moduledoc since: "0.1.0"

  @methods ["message/send", "message/stream"]

  @typedoc "What an agent returns for a request."
  @type agent_result ::
          {:ok, String.t() | Enumerable.t()}
          | {:ok, String.t() | Enumerable.t(), String.t()}
          | {:error, term()}

  @typedoc "An agent: a function of the request, or an `A2UIAgent.A2A.Agent` module."
  @type agent :: (Request.t() -> agent_result()) | module()

  @doc """
  Answers a decoded JSON-RPC request body.

  A body that is not a JSON-RPC 2.0 request, names another method or has
  no `params.message` object gets a JSON-RPC error response (codes
  -32600, -32601 and -32602).
  """
  @spec handle(term(), agent(), keyword()) ::
          {:reply, map(), [String.t()]} | {:stream, Enumerable.t(), [String.t()]}
  def handle(body, agent, options \\ [])

  def handle(%{"jsonrpc" => "2.0", "method" => method} = body, agent, options)
      when method in @methods do
    case body["params"] do
      %{"message" => %{} = message} = params ->
        body["id"]
        |> request(method, params, message, options)
        |> respond(agent_fun(agent), options)

      _other ->
        reply_error(body["id"], -32_602, "Invalid params: 'params.message' must be an object.")
    end
  end

  def handle(%{"jsonrpc" => "2.0", "method" => method} = body, _agent, _options)
      when is_binary(method),
      do: reply_error(body["id"], -32_601, "Method not found: '#{method}'.")

  def handle(body, _agent, _options),
    do: reply_error(request_id(body), -32_600, "Invalid Request: not a JSON-RPC 2.0 request.")

  @doc "A JSON-RPC error response."
  @spec error_response(term(), integer(), String.t()) :: map()
  def error_response(id, code, message),
    do: %{"jsonrpc" => "2.0", "id" => id, "error" => %{"code" => code, "message" => message}}

  defp reply_error(id, code, message), do: {:reply, error_response(id, code, message), []}

  defp request_id(%{"id" => id}) when is_binary(id) or is_integer(id), do: id
  defp request_id(_body), do: nil

  defp agent_fun(agent) when is_function(agent, 1), do: agent
  defp agent_fun(agent) when is_atom(agent), do: &agent.run/1

  # -- the request --------------------------------------------------------------------

  defp request(id, method, params, message, options) do
    parts = list(message["parts"])
    metadata = map(message["metadata"])

    requested =
      A2A.requested_extensions(
        List.wrap(options[:extensions]) ++
          List.wrap(map(params["metadata"])["X-A2A-Extensions"]) ++ list(message["extensions"])
      )

    %Request{
      id: id,
      method: method,
      message: message,
      task_id: id_or_new(message["taskId"], options),
      context_id: id_or_new(message["contextId"], options),
      text: Enum.map_join(parts, &text_of/1),
      events: A2A.a2ui_messages(parts),
      capabilities: capabilities(metadata),
      data_model: first_map([metadata["a2uiRendererDataModel"], metadata["a2uiClientDataModel"]]),
      extensions: requested,
      activated: activated(requested, options)
    }
  end

  defp list(value) when is_list(value), do: value
  defp list(_value), do: []

  defp map(value) when is_map(value), do: value
  defp map(_value), do: %{}

  defp id_or_new(id, _options) when is_binary(id) and id != "", do: id
  defp id_or_new(_id, options), do: new_id(options)

  defp text_of(%{"text" => text} = part) when is_binary(text),
    do: if(Map.get(part, "kind", "text") == "text", do: text, else: "")

  defp text_of(_part), do: ""

  # v0.9.x renderers send "a2uiClientCapabilities" (keyed "v0.9"), v1.0
  # renderers "a2uiRendererCapabilities" (keyed "v1.0"); a renderer that
  # sends both offers either.
  defp capabilities(metadata) do
    entries = [metadata["a2uiClientCapabilities"], metadata["a2uiRendererCapabilities"]]

    case Enum.filter(entries, &is_map/1) do
      [] -> nil
      maps -> Enum.reduce(maps, &Map.merge(&2, &1))
    end
  end

  defp first_map(values), do: Enum.find(values, &is_map/1)

  defp activated(requested, options) do
    case A2A.activate(requested, List.wrap(options[:advertised])) do
      {:ok, uri, version} -> {uri, version}
      :none -> nil
    end
  end

  defp activated_uris(%Request{activated: {uri, _version}}), do: [uri]
  defp activated_uris(%Request{activated: nil}), do: []

  # -- answering ----------------------------------------------------------------------

  defp respond(%Request{method: "message/send"} = request, agent, options) do
    task =
      case run(request, agent, options) do
        {:ok, request, output, state} ->
          task(request, state, output_parts(request, output_text(output)), options)

        {:error, reason} ->
          task(request, "failed", [A2A.text_part(reason_text(reason))], options)
      end

    {:reply, result(request.id, task), activated_uris(request)}
  end

  defp respond(%Request{method: "message/stream"} = request, agent, options) do
    submitted = result(request.id, task(request, "submitted", [], options))
    events = Stream.flat_map([request], &stream_events(&1, agent, options))
    {:stream, Stream.concat([submitted], events), activated_uris(request)}
  end

  defp run(request, agent, options) do
    with {:ok, request} <- negotiate(request, options),
         {:ok, output, state} <- call_agent(agent, request, options) do
      {:ok, request, output, state}
    end
  end

  defp negotiate(request, options) do
    generators = List.wrap(options[:generator])
    capabilities = request.capabilities || options[:default_capabilities]

    if generators == [] or capabilities == nil do
      {:ok, request}
    else
      with {:ok, processor} <- create_processor(generators, capabilities, nil) do
        [catalog | _] = RequestProcessor.active_catalogs(processor)
        {:ok, %{request | processor: processor, version: Catalogs.protocol_version(catalog)}}
      end
    end
  end

  defp create_processor([], _capabilities, first_error), do: {:error, first_error}

  defp create_processor([generator | rest], capabilities, first_error) do
    case Generator.create_processor(generator, capabilities) do
      {:ok, processor} -> {:ok, processor}
      {:error, error} -> create_processor(rest, capabilities, first_error || error)
    end
  end

  defp call_agent(agent, request, options) do
    case agent.(request) do
      {:ok, output} ->
        {:ok, output, Keyword.get(options, :final_state, "input-required")}

      {:ok, output, state} when is_binary(state) ->
        {:ok, output, state}

      {:error, reason} ->
        {:error, reason}

      other ->
        raise ArgumentError,
              "an A2A agent returns {:ok, output}, {:ok, output, state} or " <>
                "{:error, reason}, got: #{inspect(other)}"
    end
  end

  defp output_text(output) when is_binary(output), do: output
  defp output_text(output), do: Enum.join(output)

  defp output_chunks(output) when is_binary(output), do: [output]
  defp output_chunks(output), do: output

  defp output_parts(%Request{processor: nil}, text), do: text_parts(String.trim(text))

  defp output_parts(%Request{processor: processor, version: version}, text) do
    processor
    |> RequestProcessor.parser()
    |> A2A.response_parts(text, version, fallback_text: String.trim(text))
  end

  defp text_parts(""), do: []
  defp text_parts(text), do: [A2A.text_part(text)]

  defp reason_text(reason) when is_binary(reason), do: reason
  defp reason_text(%{__exception__: true} = exception), do: Exception.message(exception)
  defp reason_text(reason), do: inspect(reason)

  # -- streaming ----------------------------------------------------------------------

  defp stream_events(request, agent, options) do
    case run(request, agent, options) do
      {:ok, request, output, state} ->
        chunk_events(request, output_chunks(output), state, options)

      {:error, reason} ->
        [failed(request, reason, options)]
    end
  end

  defp chunk_events(request, chunks, state, options) do
    Stream.transform(
      chunks,
      fn -> reader(request) end,
      &read_chunk(&1, &2, request, options),
      &finish(&1, request, state, options),
      fn _reader -> :ok end
    )
  end

  defp reader(%Request{processor: nil}), do: {:text, false, ""}
  defp reader(%Request{processor: processor}), do: {:parser, RequestProcessor.parser(processor)}

  defp read_chunk(_chunk, :failed, _request, _options), do: {:halt, :failed}

  defp read_chunk(chunk, {:parser, parser}, request, options) do
    case A2A.chunk_parts(parser, chunk, request.version) do
      {:ok, parser, parts} -> {working(request, parts, options), {:parser, parser}}
      {:error, error} -> {[failed(request, error, options)], :failed}
    end
  end

  defp read_chunk(chunk, {:text, started, held}, request, options) do
    {text, started, held} = text_run(chunk, started, held)
    {working(request, text_parts(text), options), {:text, started, held}}
  end

  # A text-only answer is one run of text, trimmed at both ends like the
  # runs of text the parser emits: leading whitespace is dropped, and
  # trailing whitespace is held back until more text follows it.
  defp text_run(chunk, started, held) do
    text = if started, do: chunk, else: String.trim_leading(chunk)

    case String.trim_trailing(text) do
      "" ->
        {"", started, if(started, do: held <> text, else: held)}

      body ->
        {held <> body, true,
         binary_part(text, byte_size(body), byte_size(text) - byte_size(body))}
    end
  end

  defp finish(:failed, _request, _state, _options), do: {[], :failed}

  defp finish(reader, request, state, options),
    do: {[result(request.id, status_update(request, state, [], true, options))], reader}

  defp working(_request, [], _options), do: []

  defp working(request, parts, options),
    do: [result(request.id, status_update(request, "working", parts, false, options))]

  defp failed(request, reason, options) do
    parts = [A2A.text_part(reason_text(reason))]
    result(request.id, status_update(request, "failed", parts, true, options))
  end

  # -- A2A objects --------------------------------------------------------------------

  defp result(id, value), do: %{"jsonrpc" => "2.0", "id" => id, "result" => value}

  defp task(request, state, parts, options) do
    %{
      "kind" => "task",
      "id" => request.task_id,
      "contextId" => request.context_id,
      "status" => status(request, state, parts, options)
    }
  end

  defp status_update(request, state, parts, final?, options) do
    %{
      "kind" => "status-update",
      "taskId" => request.task_id,
      "contextId" => request.context_id,
      "status" => status(request, state, parts, options),
      "final" => final?
    }
  end

  defp status(_request, state, [], options), do: %{"state" => state, "timestamp" => now(options)}

  defp status(request, state, parts, options) do
    message = %{
      "kind" => "message",
      "role" => "agent",
      "messageId" => new_id(options),
      "taskId" => request.task_id,
      "contextId" => request.context_id,
      "parts" => parts
    }

    %{"state" => state, "timestamp" => now(options), "message" => message}
  end

  defp new_id(options), do: Keyword.get(options, :id_generator, &uuid4/0).()
  defp now(options), do: Keyword.get(options, :clock, &utc_now/0).()

  defp utc_now, do: DateTime.to_iso8601(DateTime.utc_now())

  defp uuid4 do
    <<a::48, _::4, b::12, _::2, c::62>> = :crypto.strong_rand_bytes(16)

    <<p1::binary-8, p2::binary-4, p3::binary-4, p4::binary-4, p5::binary-12>> =
      Base.encode16(<<a::48, 4::4, b::12, 2::2, c::62>>, case: :lower)

    Enum.join([p1, p2, p3, p4, p5], "-")
  end
end

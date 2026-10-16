defmodule GalleryWeb.ChatLive do
  @moduledoc """
  A conversation with the restaurant agent (`examples/restaurant_agent`)
  over A2A. What the user types goes out as a text part; the agent's
  answer streams back as text and A2UI parts; what the surfaces send
  (actions, function calls and responses, errors) goes back as A2UI data
  parts. Every message carries the renderer's capabilities and the data
  models of the surfaces that asked for them, in its metadata.

  One request runs at a time: what the surfaces send meanwhile waits and
  goes out together when the answer is complete.
  """

  use GalleryWeb, :live_view

  alias A2UIAgent.A2A
  alias A2UIPhoenix.{Live, Session}
  alias Gallery.{A2AClient, Catalogs}
  alias GalleryWeb.{Markdown, RestaurantComponents, Telemetry}

  @suggestions ["Find Italian restaurants", "Something Japanese, please", "What is near me?"]
  @max_log 150

  @impl true
  def mount(_params, _session, socket) do
    session =
      Session.new([Catalogs.basic("v1.0"), Catalogs.restaurant()], default_timeout_ms: 15_000)

    socket =
      socket
      |> assign(
        page_title: "Restaurant agent",
        agent_url: Application.get_env(:gallery, :agent_url),
        card: nil,
        problem: nil,
        transcript: [],
        speaking: nil,
        context_id: nil,
        request: nil,
        queue: [],
        log: [],
        suggestions: @suggestions
      )
      |> Live.init(session, on_send: &on_send/2, on_effect: &on_effect/2)

    {:ok, if(connected?(socket), do: load_card(socket), else: socket)}
  end

  defp load_card(socket) do
    case A2AClient.agent_card(socket.assigns.agent_url) do
      {:ok, card} ->
        assign(socket, card: card, problem: nil)

      {:error, reason} ->
        assign(socket,
          problem: "The agent at #{socket.assigns.agent_url} does not answer (#{reason})."
        )
    end
  end

  # -- the user ---------------------------------------------------------------------

  @impl true
  def handle_event("send", %{"text" => text}, socket),
    do: {:noreply, say(socket, String.trim(text))}

  def handle_event("suggest", %{"text" => text}, socket), do: {:noreply, say(socket, text)}
  def handle_event("retry", _params, socket), do: {:noreply, load_card(socket)}

  defp say(socket, ""), do: socket

  defp say(socket, text) do
    socket
    |> add(:user, text)
    |> assign(:suggestions, [])
    |> request([A2A.text_part(text)])
  end

  # -- requests -----------------------------------------------------------------------

  defp request(%{assigns: %{request: nil}} = socket, parts) do
    live = self()
    ref = make_ref()

    options = [
      url: socket.assigns.agent_url <> "/a2a",
      parts: parts,
      metadata: metadata(socket),
      context_id: socket.assigns.context_id,
      to: live,
      ref: ref
    ]

    Task.start(fn -> A2AClient.stream(options) end)
    assign(socket, request: ref, speaking: nil)
  end

  defp request(socket, parts), do: update(socket, :queue, &(&1 ++ parts))

  # The renderer's capabilities and the data models that travel with
  # every message.
  defp metadata(socket) do
    session = Live.session(socket)

    {:ok, capabilities} =
      A2UICore.Processor.renderer_capabilities(session.processor, versions: ["v1.0"])

    case Session.client_data_model(session, "v1.0") do
      {:ok, nil} ->
        %{"a2uiRendererCapabilities" => capabilities}

      {:ok, data_model} ->
        %{"a2uiRendererCapabilities" => capabilities, "a2uiRendererDataModel" => data_model}

      {:error, _error} ->
        %{"a2uiRendererCapabilities" => capabilities}
    end
  end

  @impl true
  def handle_info({:a2a_parts, ref, parts, context_id}, %{assigns: %{request: ref}} = socket) do
    socket = if context_id, do: assign(socket, :context_id, context_id), else: socket
    {:noreply, Enum.reduce(parts, socket, &part/2)}
  end

  def handle_info({:a2a_done, ref, outcome}, %{assigns: %{request: ref}} = socket) do
    socket =
      case outcome do
        :ok -> socket
        {:error, reason} -> add(socket, :system, "The agent could not be reached: #{reason}")
      end

    queued = socket.assigns.queue
    socket = assign(socket, request: nil, queue: [], speaking: nil)
    {:noreply, if(queued == [], do: socket, else: request(socket, queued))}
  end

  # What a request that is no longer current still reports.
  def handle_info({:a2a_parts, _ref, _parts, _context_id}, socket), do: {:noreply, socket}
  def handle_info({:a2a_done, _ref, _outcome}, socket), do: {:noreply, socket}

  defp part(%{"kind" => "text", "text" => text}, socket), do: speak(socket, text)

  defp part(part, socket) do
    case A2A.a2ui_messages([part]) do
      [] -> socket
      messages -> agent(socket, messages)
    end
  end

  defp agent(socket, messages) do
    socket = log(socket, Enum.map(messages, &entry(:in, &1)))
    started = System.monotonic_time()
    {result, socket} = Live.handle_message(socket, messages)
    each = div(System.monotonic_time() - started, max(length(messages), 1))
    Enum.each(messages, &Telemetry.message(:in, &1, "chat", each))

    case result do
      :ok ->
        socket

      {:error, error} ->
        log(socket, [%{direction: :effect, kind: "rejected", note: error.message}])
    end
  end

  defp on_send(message, socket) do
    Telemetry.message(:out, message, "chat")

    socket
    |> log([entry(:out, message)])
    |> request([A2A.a2ui_part(message, "v1.0")])
  end

  defp on_effect({:surface_created, id}, socket), do: add(socket, :surface, id)

  defp on_effect({:surface_deleted, id}, socket),
    do:
      update(socket, :transcript, fn items ->
        Enum.reject(items, &(&1.role == :surface and &1.text == id))
      end)

  defp on_effect({:diagnostic, surface_id, level, payload}, socket),
    do:
      log(socket, [
        %{
          direction: :effect,
          kind: "#{level}",
          note: "#{surface_id}: #{payload[:code]} #{payload[:message]}"
        }
      ])

  defp on_effect({:rpc_settled, call_id, outcome}, socket) do
    note =
      case outcome do
        {:ok, value} -> "#{call_id} answered: #{Jason.encode!(value)}"
        {:error, error} -> "#{call_id} failed: #{error.code}"
      end

    log(socket, [%{direction: :effect, kind: "agent call settled", note: note}])
  end

  defp on_effect(_effect, socket), do: socket

  # -- the transcript ---------------------------------------------------------------

  # Text the agent streams extends its bubble, until something else is
  # added after it.
  defp speak(socket, text) do
    case {socket.assigns.speaking, List.last(socket.assigns.transcript)} do
      {key, %{key: key}} when key != nil ->
        update(socket, :transcript, fn items ->
          List.update_at(items, -1, &%{&1 | text: &1.text <> text})
        end)

      _other ->
        socket = add(socket, :agent, text)
        assign(socket, :speaking, List.last(socket.assigns.transcript).key)
    end
  end

  defp add(socket, role, text) do
    item = %{key: System.unique_integer([:positive, :monotonic]), role: role, text: text}
    update(socket, :transcript, &(&1 ++ [item]))
  end

  defp entry(direction, message),
    do: %{
      direction: direction,
      kind: Gallery.Scenario.Messages.kind(message),
      json: pretty(message),
      note: nil
    }

  # Each entry has an id, so that the log keeps what is expanded as it grows.
  defp log(socket, entries) do
    entries = Enum.map(entries, &Map.put(&1, :id, System.unique_integer([:positive, :monotonic])))
    update(socket, :log, &Enum.take(Enum.reverse(entries) ++ &1, @max_log))
  end

  # -- the page -----------------------------------------------------------------------

  @impl true
  def render(assigns) do
    ~H"""
    <div class="ui-chat">
      <.panel class="ui-conversation">
        <div class="ui-conversation-head" id="chat-head">
          <span class="ui-agent-avatar"><.icon name="chat" /></span>
          <div class="ui-agent-info">
            <h1 class="ui-agent-name">{(@card && @card["name"]) || "Restaurant agent"}</h1>
            <p :if={@card && @card["description"]} class="ui-agent-description">
              {@card["description"]}
            </p>
            <p class="ui-agent-meta">
              <code>{@agent_url}</code>
              <span :if={@card}>A2A {@card["protocolVersion"]}</span>
              <.badge :for={extension <- extensions(@card)} tone="accent">{extension}</.badge>
            </p>
          </div>
          <.status :if={@problem} tone="danger">unreachable</.status>
          <.status :if={!@problem and @request != nil} tone="busy">the agent is answering…</.status>
          <.status :if={!@problem and @request == nil and @card != nil} tone="success">
            connected
          </.status>
        </div>

        <div class="ui-transcript" id="transcript" phx-hook="ScrollToEnd">
          <.callout :if={@problem} tone="warning" id="problem" title="The agent is not running">
            <p>{@problem}</p>
            <p>
              Start it with <code>cd examples/restaurant_agent &amp;&amp; mix run --no-halt</code>, then
            </p>
            <div><.button size="sm" icon="replay" phx-click="retry">Try again</.button></div>
          </.callout>
          <%= for item <- @transcript do %>
            <.bubble :if={item.role == :user} role="user" id={"t-#{item.key}"}>{item.text}</.bubble>
            <.bubble :if={item.role == :agent} role="agent" id={"t-#{item.key}"}>
              {Phoenix.HTML.raw(Markdown.to_html(item.text))}
            </.bubble>
            <.bubble :if={item.role == :system} role="system" id={"t-#{item.key}"}>
              {item.text}
            </.bubble>
            <.surface_frame
              :if={item.role == :surface and Session.surface(@a2ui, item.text) != nil}
              id={"frame-" <> item.text}
              surface_id={item.text}
            >
              <.live_component
                module={A2UIPhoenix.Surface}
                id={"surface-" <> item.text}
                session={@a2ui}
                surface_id={item.text}
                components={RestaurantComponents.components()}
                markdown={&Markdown.to_html/1}
              />
            </.surface_frame>
          <% end %>
          <.bubble :if={@transcript == [] and @problem == nil} role="system" id="t-empty">
            Ask for a cuisine to see restaurants, then book a table.
          </.bubble>
        </div>

        <div class="ui-composer">
          <div class="ui-suggestions" id="suggestions">
            <.button
              :for={text <- @suggestions}
              size="sm"
              variant="ghost"
              phx-click="suggest"
              phx-value-text={text}
              disabled={@problem != nil}
            >
              {text}
            </.button>
          </div>
          <form id="composer" phx-submit="send">
            <input
              type="text"
              name="text"
              class="ui-input"
              placeholder="Ask the agent…"
              aria-label="Your message"
              autocomplete="off"
              disabled={@problem != nil}
            />
            <.button type="submit" variant="primary" icon="send" disabled={@problem != nil}>
              Send
            </.button>
          </form>
        </div>
      </.panel>

      <.panel class="ui-inspector">
        <:head>
          <h2 class="ui-panel-title">Messages</h2>
          <.badge>{length(@log)}</.badge>
        </:head>
        <div class="ui-inspector-body">
          <.message_log id="log" entries={@log} />
          <.empty :if={@log == []}>
            What crosses between the agent and the renderer shows here.
          </.empty>
        </div>
      </.panel>
    </div>
    """
  end

  defp extensions(nil), do: []

  defp extensions(card),
    do: card |> A2A.advertised_extensions() |> Enum.map(&extension_label/1)

  # The A2UI extension's URI ends with its protocol version.
  defp extension_label(uri), do: uri |> String.split("/") |> Enum.take(-2) |> Enum.join("/")
end

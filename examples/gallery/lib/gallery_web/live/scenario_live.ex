defmodule GalleryWeb.ScenarioLive do
  @moduledoc """
  Runs a `Gallery.Scenario`: an `A2UIPhoenix.Session` fed by the
  scenario's scripted agent, the surfaces it builds, and an inspector
  with every message in both directions and each surface's data model.
  """

  use GalleryWeb, :live_view

  alias A2UIPhoenix.{Live, Session}
  alias Gallery.Scenario
  alias GalleryWeb.{Markdown, RestaurantComponents, Telemetry}

  @max_log 120

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    case Scenario.get(id) do
      nil -> raise GalleryWeb.NotFoundError, "No scenario #{id}"
      scenario -> {:ok, start(socket, scenario)}
    end
  end

  defp start(socket, scenario) do
    session = Session.new(scenario.catalogs(), scenario.session_options())

    socket
    |> assign(
      scenario: scenario,
      page_title: scenario.title(),
      log: [],
      said: [],
      tab: "messages",
      ticks: 0
    )
    |> Live.init(session, on_send: &on_send/2, on_effect: &on_effect/2)
    |> agent(scenario.messages())
    |> schedule(scenario.start())
    |> schedule_tick()
  end

  # The agent answers after a delay, as a real one would; `:delay_scale`
  # shortens the delays (the tests run them twenty times faster).
  defp later({delay, payload}) do
    scale = Application.get_env(:gallery, :delay_scale, 1)
    Process.send_after(self(), {:agent, payload}, round(delay * scale))
  end

  defp schedule(socket, replies) do
    if connected?(socket),
      do: Enum.each(replies, &later/1)

    socket
  end

  # -- the agent ------------------------------------------------------------------

  @impl true
  def handle_info({:agent, {:text, text}}, socket) do
    socket =
      socket
      |> update(:said, &Enum.take([text | &1], 3))
      |> log([%{direction: :in, kind: "text", note: text}])

    {:noreply, socket}
  end

  # More of what the agent is saying: it extends the last bubble and its
  # log entry.
  def handle_info({:agent, {:text_delta, text}}, socket) do
    said =
      case socket.assigns.said do
        [last | earlier] -> [last <> text | earlier]
        [] -> [text]
      end

    log =
      case socket.assigns.log do
        [%{kind: "text"} = entry | earlier] -> [%{entry | note: entry.note <> text} | earlier]
        log -> log
      end

    {:noreply, assign(socket, said: said, log: log)}
  end

  def handle_info({:agent, payload}, socket), do: {:noreply, agent(socket, payload)}

  def handle_info(:tick, socket) do
    ticks = socket.assigns.ticks + 1

    case socket.assigns.scenario.tick(ticks) do
      nil ->
        {:noreply, socket}

      messages ->
        {:noreply, socket |> assign(:ticks, ticks) |> agent(messages) |> schedule_tick()}
    end
  end

  defp schedule_tick(socket) do
    if connected?(socket) and socket.assigns.scenario.tick(socket.assigns.ticks + 1) != nil,
      do: Process.send_after(self(), :tick, Application.get_env(:gallery, :tick_ms, 1_000))

    socket
  end

  defp agent(socket, []), do: socket

  # The messages are logged first, so what they make the renderer send
  # comes after them.
  defp agent(socket, payload) do
    messages = List.wrap(payload)
    socket = log(socket, Enum.map(messages, &entry(:in, &1)))
    started = System.monotonic_time()
    {result, socket} = Live.handle_message(socket, messages)
    each = div(System.monotonic_time() - started, max(length(messages), 1))
    Enum.each(messages, &Telemetry.message(:in, &1, "scenario", each))

    case result do
      :ok ->
        socket

      {:error, error} ->
        log(socket, [%{direction: :effect, kind: "rejected", note: error.message}])
    end
  end

  defp on_send(message, socket) do
    Telemetry.message(:out, message, "scenario")
    data_models = data_models(socket)
    socket = log(socket, [entry(:out, message, data_model_note(data_models))])

    Enum.each(socket.assigns.scenario.reply(message, data_models), &later/1)

    socket
  end

  # What the transport would attach: the data models of the surfaces
  # created with sendDataModel.
  defp data_models(socket) do
    case Session.client_data_model(Live.session(socket)) do
      {:ok, %{"surfaces" => surfaces}} -> surfaces
      _none -> %{}
    end
  end

  defp data_model_note(data_models) when map_size(data_models) == 0, do: nil

  defp data_model_note(data_models),
    do: "with the data model of " <> Enum.join(Map.keys(data_models), ", ")

  defp on_effect({:diagnostic, surface_id, level, payload}, socket) do
    note = "#{surface_id}: #{payload[:code]} #{payload[:message]}"
    log(socket, [%{direction: :effect, kind: "#{level}", note: note}])
  end

  defp on_effect({:rpc_settled, call_id, outcome}, socket) do
    note =
      case outcome do
        {:ok, value} -> "#{call_id} answered: #{Jason.encode!(value)}"
        {:error, error} -> "#{call_id} failed: #{error.code}"
      end

    log(socket, [%{direction: :effect, kind: "agent call settled", note: note}])
  end

  defp on_effect({:agent_call_sent, call_id, timeout}, socket),
    do:
      log(socket, [
        %{
          direction: :effect,
          kind: "agent call sent",
          note: "#{call_id}, times out after #{timeout} ms"
        }
      ])

  defp on_effect(_effect, socket), do: socket

  defp entry(direction, message, note \\ nil),
    do: %{
      direction: direction,
      kind: Gallery.Scenario.Messages.kind(message),
      json: pretty(message),
      note: note
    }

  # Each entry has an id, so that the log keeps what is expanded as it grows.
  defp log(socket, entries) do
    entries = Enum.map(entries, &Map.put(&1, :id, System.unique_integer([:positive, :monotonic])))
    update(socket, :log, &Enum.take(Enum.reverse(entries) ++ &1, @max_log))
  end

  # -- the page ---------------------------------------------------------------------

  @impl true
  def handle_event("control", %{"id" => id}, socket) do
    scenario = socket.assigns.scenario
    label = Enum.find_value(scenario.controls(), id, fn {key, label} -> key == id && label end)
    socket = log(socket, [%{direction: :user, kind: "control", note: label}])

    Enum.each(scenario.control(id), &later/1)

    {:noreply, socket}
  end

  def handle_event("tab", %{"tab" => tab}, socket), do: {:noreply, assign(socket, :tab, tab)}

  def handle_event("restart", _params, socket),
    do: {:noreply, push_navigate(socket, to: "/scenarios/#{socket.assigns.scenario.id()}")}

  defp capabilities(session) do
    versions =
      session.processor |> A2UICore.Processor.surfaces() |> Enum.map(& &1.version) |> Enum.uniq()

    {:ok, capabilities} =
      A2UICore.Processor.renderer_capabilities(session.processor,
        versions: if(versions == [], do: ["v1.0"], else: versions),
        include_inline_catalogs: true
      )

    capabilities
  end

  @impl true
  def render(assigns) do
    assigns =
      assign(assigns,
        surfaces: Session.surfaces(assigns.a2ui),
        number: number(assigns.scenario)
      )

    ~H"""
    <.page_header id="scenario-head">
      <:eyebrow>
        <.link navigate="/"><.icon name="arrow-left" />Scenarios</.link>
        <span aria-hidden="true">/</span> {@number}
      </:eyebrow>
      <:title>{@scenario.title()}</:title>
      <p>{@scenario.summary()}</p>
      <.tags items={@scenario.features()} />
      <:actions>
        <.button variant="secondary" icon="replay" phx-click="restart">Start over</.button>
      </:actions>
    </.page_header>

    <div class="ui-workbench">
      <section class="ui-stage" aria-label="What the renderer shows">
        <div :if={@scenario.controls() != []} class="ui-toolbar" id="controls">
          <span class="ui-toolbar-label"><.icon name="bolt" />Agent</span>
          <div class="ui-toolbar-actions">
            <.button
              :for={{id, label} <- @scenario.controls()}
              size="sm"
              phx-click="control"
              phx-value-id={id}
            >
              {label}
            </.button>
          </div>
        </div>
        <.canvas id="stage">
          <%!-- Always there, so that the first bubble does not make the DOM
               patch move the surfaces: moving an iframe reloads it, and an
               embedded MCP App would start over. --%>
          <div class="ui-said" id="said" hidden={@said == []}>
            <.bubble :for={text <- Enum.reverse(@said)} role="agent">{text}</.bubble>
          </div>
          <div class="ui-surfaces" id="surfaces">
            <.surface_frame
              :for={surface <- @surfaces}
              id={"frame-" <> surface.id}
              surface_id={surface.id}
              version={surface.version}
            >
              <.live_component
                module={A2UIPhoenix.Surface}
                id={"surface-" <> surface.id}
                session={@a2ui}
                surface_id={surface.id}
                components={Map.merge(RestaurantComponents.components(), @scenario.components())}
                markdown={&Markdown.to_html/1}
              />
            </.surface_frame>
            <.empty :if={@surfaces == []}>No surfaces yet.</.empty>
          </div>
        </.canvas>
      </section>

      <.panel class="ui-inspector">
        <:head>
          <.tabs
            label="Inspector"
            active={@tab}
            tabs={[
              {"messages", "Messages"},
              {"data", "Data models"},
              {"capabilities", "Capabilities"},
              {"script", "Script"}
            ]}
          />
          <.badge :if={@tab == "messages"}>{length(@log)}</.badge>
        </:head>
        <div class="ui-inspector-body">
          <.message_log :if={@tab == "messages"} id="log" entries={@log} />
          <.empty :if={@tab == "messages" and @log == []}>No messages yet.</.empty>
          <div :if={@tab == "data"} class="data-models">
            <div :for={surface <- @surfaces} class="ui-model">
              <p class="ui-model-title">
                {surface.id}
                <.badge>{surface.version}</.badge>
              </p>
              <.code code={pretty(surface.data_model.data)} />
            </div>
            <.empty :if={@surfaces == []}>No surfaces, so no data models.</.empty>
          </div>
          <div :if={@tab == "capabilities"} class="data-models">
            <p class="ui-inspector-note">
              What this renderer tells the agent it supports, with each catalog inline, as it
              travels in the transport's metadata.
            </p>
            <.code code={pretty(capabilities(@a2ui))} class="ui-model-code" />
          </div>
          <.code
            :if={@tab == "script"}
            code={@scenario.script() || pretty(@scenario.messages())}
            class={["ui-model-code", @scenario.script() && "ui-code-wrap"]}
          />
        </div>
      </.panel>
    </div>
    """
  end

  defp number(scenario) do
    index = Enum.find_index(Scenario.all(), &(&1 == scenario)) || 0
    index |> Kernel.+(1) |> Integer.to_string() |> String.pad_leading(2, "0")
  end
end

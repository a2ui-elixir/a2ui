defmodule GalleryWeb.ExamplesLive do
  @moduledoc """
  The example surfaces of the A2UI project (`catalogs/basic/v1/examples`
  in the reference checkout), each rendered from its own messages. The
  checkout is found at `A2UI_REFERENCE_ROOT`, else at `reference/a2ui`
  in this repository.
  """

  use GalleryWeb, :live_view

  alias A2UIPhoenix.{Live, Session}
  alias GalleryWeb.Markdown

  @impl true
  def mount(params, _session, socket) do
    bundles = bundles()
    name = params["name"] || bundles |> List.first(%{}) |> Map.get(:name)
    bundle = Enum.find(bundles, &(&1.name == name))

    session = Session.new([Gallery.Catalogs.basic("v1.0")])

    socket =
      socket
      |> assign(bundles: bundles, bundle: bundle, notes: [], page_title: "Reference examples")
      |> Live.init(session, on_send: &on_send/2, on_effect: &on_effect/2)

    socket =
      case bundle do
        nil ->
          socket

        bundle ->
          case Live.handle_message(socket, bundle.messages) do
            {:ok, socket} -> socket
            {{:error, error}, socket} -> note(socket, "rejected", error.message)
          end
      end

    {:ok, socket}
  end

  # There is no agent here: what the surface would send is listed.
  defp on_send(%{"action" => action}, socket),
    do: note(socket, "action", "#{action["name"]} #{Jason.encode!(action["context"] || %{})}")

  defp on_send(message, socket), do: note(socket, "sent", Jason.encode!(message))

  defp on_effect({:diagnostic, _surface_id, level, payload}, socket),
    do: note(socket, "#{level}", "#{payload[:code]} #{payload[:message]}")

  defp on_effect({:open_url, url}, socket), do: note(socket, "openUrl", url)
  defp on_effect(_effect, socket), do: socket

  defp note(socket, kind, text), do: update(socket, :notes, &(&1 ++ [%{kind: kind, text: text}]))

  @doc "The reference's example bundles, or `[]` without the checkout."
  def bundles do
    root =
      System.get_env("A2UI_REFERENCE_ROOT") ||
        Path.expand("../../../../../reference/a2ui", __DIR__)

    root
    |> Path.join("catalogs/basic/v1/examples/*.json")
    |> Path.wildcard()
    |> Enum.sort()
    |> Enum.map(fn file ->
      document = file |> File.read!() |> Jason.decode!()

      %{
        name: Path.basename(file, ".json"),
        title: document["name"],
        description: document["description"],
        messages: document["messages"]
      }
    end)
  end

  @impl true
  def render(assigns) do
    ~H"""
    <.page_header>
      <:eyebrow>The A2UI project · catalogs/basic/v1/examples</:eyebrow>
      <:title>Reference examples</:title>
      <p>
        The A2UI project's own example surfaces, each rendered by <code>A2UIPhoenix</code>
        from its messages, with what it would send to an agent.
      </p>
    </.page_header>

    <.callout :if={@bundles == []} tone="warning" title="The reference checkout was not found">
      <p>
        Clone it as the repository's README explains, or point <code>A2UI_REFERENCE_ROOT</code>
        at one.
      </p>
    </.callout>

    <div :if={@bundles != []} class="ui-browser">
      <.panel class="ui-sidebar">
        <nav aria-label="Examples">
          <.link
            :for={{bundle, index} <- Enum.with_index(@bundles, 1)}
            navigate={"/examples/" <> bundle.name}
            aria-current={if @bundle && @bundle.name == bundle.name, do: "page"}
          >
            <span class="ui-sidebar-number">{number(index)}</span>
            <span>{bundle.title || bundle.name}</span>
          </.link>
        </nav>
      </.panel>

      <section :if={@bundle} class="ui-stage" aria-label={@bundle.title}>
        <header class="ui-example-head">
          <h2 class="ui-example-title">{@bundle.title || @bundle.name}</h2>
          <p :if={@bundle.description} class="ui-example-text">{@bundle.description}</p>
          <.tags items={[@bundle.name <> ".json"]} />
        </header>
        <.canvas>
          <.surface_frame
            :for={surface <- Session.surfaces(@a2ui)}
            id={"frame-" <> surface.id}
            surface_id={surface.id}
            version={surface.version}
          >
            <.live_component
              module={A2UIPhoenix.Surface}
              id={"surface-" <> surface.id}
              session={@a2ui}
              surface_id={surface.id}
              markdown={&Markdown.to_html/1}
            />
          </.surface_frame>
        </.canvas>
        <.panel :if={@notes != []}>
          <:head>
            <h3 class="ui-panel-title">Renderer output</h3>
            <.badge>{length(@notes)}</.badge>
          </:head>
          <ul class="ui-notes" id="notes">
            <li :for={note <- @notes} class="ui-note" data-kind={note.kind}>
              <.badge tone={tone(note.kind)}>{note.kind}</.badge>
              <span class="ui-note-text">{note.text}</span>
            </li>
          </ul>
        </.panel>
        <details class="ui-panel ui-disclosure" phx-mounted={JS.ignore_attributes(["open"])}>
          <summary>
            <.icon name="braces" />
            <span>Messages</span>
            <.badge>{length(@bundle.messages)}</.badge>
            <.icon name="chevron" class="ui-icon ui-log-chevron" />
          </summary>
          <.code code={pretty(@bundle.messages)} />
        </details>
      </section>
    </div>
    """
  end

  defp number(index), do: index |> Integer.to_string() |> String.pad_leading(2, "0")

  defp tone(kind) when kind in ["error", "rejected"], do: "danger"
  defp tone("warning"), do: "warning"
  defp tone(kind) when kind in ["action", "sent"], do: "accent"
  defp tone(_kind), do: "info"
end

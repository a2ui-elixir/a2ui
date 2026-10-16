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
    <h1>Reference examples</h1>
    <p :if={@bundles == []} class="lead">
      The reference checkout was not found. Clone it as the repository's README explains, or
      point <code>A2UI_REFERENCE_ROOT</code> at one.
    </p>
    <div :if={@bundles != []} class="examples">
      <nav>
        <.link
          :for={bundle <- @bundles}
          navigate={"/examples/" <> bundle.name}
          class={@bundle && @bundle.name == bundle.name && "active"}
        >
          {bundle.title || bundle.name}
        </.link>
      </nav>
      <section :if={@bundle}>
        <h2>{@bundle.title}</h2>
        <p class="summary">{@bundle.description}</p>
        <div :for={surface <- Session.surfaces(@a2ui)} class="surface-frame">
          <div class="surface-id">{surface.id}</div>
          <.live_component
            module={A2UIPhoenix.Surface}
            id={"surface-" <> surface.id}
            session={@a2ui}
            surface_id={surface.id}
            markdown={&Markdown.to_html/1}
          />
        </div>
        <ul :if={@notes != []} class="notes" id="notes">
          <li :for={note <- @notes} class={"note-" <> note.kind}><b>{note.kind}</b> {note.text}</li>
        </ul>
        <details>
          <summary>Messages</summary>
          <pre>{pretty(@bundle.messages)}</pre>
        </details>
      </section>
    </div>
    """
  end
end

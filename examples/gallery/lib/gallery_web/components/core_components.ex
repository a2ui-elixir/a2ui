defmodule GalleryWeb.CoreComponents do
  @moduledoc """
  The gallery's UI kit: every page is made of these components. They draw
  with the same `--a2ui-*` tokens as the surfaces they show
  (`a2ui_phoenix.css`), plus a few of the gallery's own
  (`priv/static/assets/gallery.css`), so the pages and the surfaces are
  one design, in light and dark.
  """

  use Phoenix.Component

  alias Phoenix.LiveView.JS

  @icons %{
    "arrow-right" => ~S(<path d="M5 12h14"/><path d="m13 6 6 6-6 6"/>),
    "arrow-left" => ~S(<path d="M19 12H5"/><path d="m11 18-6-6 6-6"/>),
    "chevron" => ~S(<path d="m9 6 6 6-6 6"/>),
    "sun" =>
      ~S(<circle cx="12" cy="12" r="4"/><path d="M12 2.5v2M12 19.5v2M4.6 4.6l1.4 1.4M18 18l1.4 1.4M2.5 12h2M19.5 12h2M4.6 19.4 6 18M18 6l1.4-1.4"/>),
    "moon" => ~S(<path d="M20.5 14.5A8.5 8.5 0 0 1 9.5 3.5a8.5 8.5 0 1 0 11 11Z"/>),
    "replay" => ~S(<path d="M3.5 12a8.5 8.5 0 1 0 2.6-6.1"/><path d="M3.5 4v4.5H8"/>),
    "send" => ~S(<path d="M4 12 20 4l-4 16-4-7-8-1Z"/><path d="m12 13 8-9"/>),
    "bolt" => ~S(<path d="M13 2.5 4.5 13.5H12l-1 8 8.5-11H12l1-8Z"/>),
    "window" =>
      ~S(<rect x="3" y="4" width="18" height="16" rx="3"/><path d="M3 9h18"/><path d="M6.5 6.5h.01M9 6.5h.01"/>),
    "grid" =>
      ~S(<rect x="3.5" y="3.5" width="7" height="7" rx="1.8"/><rect x="13.5" y="3.5" width="7" height="7" rx="1.8"/><rect x="3.5" y="13.5" width="7" height="7" rx="1.8"/><rect x="13.5" y="13.5" width="7" height="7" rx="1.8"/>),
    "book" =>
      ~S(<path d="M4 5.5A2.5 2.5 0 0 1 6.5 3H20v15H6.5A2.5 2.5 0 0 0 4 20.5v-15Z"/><path d="M4 20.5A2.5 2.5 0 0 1 6.5 18H20v3H6.5"/>),
    "chat" =>
      ~S(<path d="M4 5.5A1.5 1.5 0 0 1 5.5 4h13A1.5 1.5 0 0 1 20 5.5v9a1.5 1.5 0 0 1-1.5 1.5H10l-4.5 3.8V16H5.5A1.5 1.5 0 0 1 4 14.5v-9Z"/>),
    "gauge" => ~S(<path d="M4 18a8 8 0 1 1 16 0"/><path d="m12 18 4-6"/><path d="M12 18h.01"/>),
    "form" =>
      ~S(<rect x="3.5" y="4" width="17" height="16" rx="2.5"/><path d="M7 8.5h6"/><rect x="7" y="11.5" width="10" height="3.5" rx="1"/><path d="M7 18h3"/>),
    "braces" =>
      ~S(<path d="M8 3H7a2 2 0 0 0-2 2v4a2 2 0 0 1-2 2 2 2 0 0 1 2 2v4a2 2 0 0 0 2 2h1"/><path d="M16 3h1a2 2 0 0 1 2 2v4a2 2 0 0 0 2 2 2 2 0 0 0-2 2v4a2 2 0 0 1-2 2h-1"/>),
    "layers" =>
      ~S(<path d="M12 3 2.5 8 12 13l9.5-5L12 3Z"/><path d="M2.5 12.5 12 17.5l9.5-5"/><path d="M2.5 17 12 22l9.5-5"/>),
    "function" =>
      ~S(<path d="M4 8h13"/><path d="m14 4 4 4-4 4"/><path d="M20 16H7"/><path d="m10 12-4 4 4 4"/>),
    "puzzle" =>
      ~S(<path d="M9 4h6v3a2 2 0 1 0 4 0V4h1v6h-3a2 2 0 1 0 0 4h3v6h-6v-3a2 2 0 1 0-4 0v3H4v-6h3a2 2 0 1 0 0-4H4V4h5Z"/>),
    "stream" => ~S(<path d="M4 6h9"/><path d="M4 10h14"/><path d="M4 14h7"/><path d="M4 18h11"/>),
    "plug" =>
      ~S(<path d="M9 2.5v4.5"/><path d="M15 2.5v4.5"/><path d="M6 7h12v4a6 6 0 0 1-12 0V7Z"/><path d="M12 17v4.5"/>),
    "alert" =>
      ~S(<path d="M12 3.5 2.5 20h19L12 3.5Z"/><path d="M12 10v4.5"/><path d="M12 17.5h.01"/>),
    "info" => ~S(<circle cx="12" cy="12" r="9"/><path d="M12 11v5.5"/><path d="M12 7.5h.01"/>),
    "history" =>
      ~S(<path d="M3.5 12a8.5 8.5 0 1 0 2.6-6.1"/><path d="M3.5 4v4.5H8"/><path d="M12 7.5V12l3 2"/>),
    "external" =>
      ~S(<path d="M14 4h6v6"/><path d="M20 4 11 13"/><path d="M18 14v5a1 1 0 0 1-1 1H5a1 1 0 0 1-1-1V7a1 1 0 0 1 1-1h5"/>),
    "logo" =>
      ~S(<path d="M12 3.2c3.5 4.5 6.3 8.2 6.3 11.7a6.3 6.3 0 0 1-12.6 0c0-3.5 2.8-7.2 6.3-11.7Z"/><path d="M9.2 15.2a2.8 2.8 0 0 0 5.6 0"/>)
  }

  @doc "The names of the UI kit's icons."
  def icon_names, do: Map.keys(@icons)

  @doc "A stroke icon; decorative unless given a `label`."
  attr :name, :string, required: true
  attr :class, :string, default: "ui-icon"
  attr :label, :string, default: nil

  def icon(assigns) do
    assigns = assign(assigns, :paths, Map.fetch!(@icons, assigns.name))

    ~H"""
    <svg
      class={@class}
      viewBox="0 0 24 24"
      fill="none"
      stroke="currentColor"
      stroke-width="1.75"
      stroke-linecap="round"
      stroke-linejoin="round"
      role={@label && "img"}
      aria-label={@label}
      aria-hidden={if(@label, do: nil, else: "true")}
    >
      {Phoenix.HTML.raw(@paths)}
    </svg>
    """
  end

  @doc "A button: `primary`, `secondary` or `ghost`, in two sizes, with an optional icon."
  attr :variant, :string, default: "secondary", values: ~w(primary secondary ghost)
  attr :size, :string, default: "md", values: ~w(sm md)
  attr :icon, :string, default: nil
  attr :type, :string, default: "button"
  attr :class, :any, default: nil
  attr :rest, :global, include: ~w(disabled form name value)
  slot :inner_block

  def button(assigns) do
    ~H"""
    <button
      type={@type}
      class={["ui-button", "ui-button-" <> @variant, "ui-button-" <> @size, @class]}
      {@rest}
    >
      <.icon :if={@icon} name={@icon} />{render_slot(@inner_block)}
    </button>
    """
  end

  @doc "Feature tags: short mono labels."
  attr :items, :list, required: true
  attr :class, :any, default: nil

  def tags(assigns) do
    ~H"""
    <ul class={["ui-tags", @class]}>
      <li :for={item <- @items} class="ui-tag">{item}</li>
    </ul>
    """
  end

  @doc "A badge: a short label with a tone."
  attr :tone, :string,
    default: "neutral",
    values: ~w(neutral accent success warning danger info)

  attr :class, :any, default: nil
  attr :rest, :global
  slot :inner_block, required: true

  def badge(assigns) do
    ~H"""
    <span class={["ui-badge", "ui-badge-" <> @tone, @class]} {@rest}>{render_slot(@inner_block)}</span>
    """
  end

  @doc "A status: a dot and what it says."
  attr :tone, :string, default: "neutral", values: ~w(neutral success warning danger busy)
  attr :rest, :global
  slot :inner_block, required: true

  def status(assigns) do
    ~H"""
    <span class={["ui-status", "ui-status-" <> @tone]} {@rest}>
      <i class="ui-status-dot" aria-hidden="true"></i>{render_slot(@inner_block)}
    </span>
    """
  end

  @doc "The head of a page: eyebrow, title, lead, and actions on the side."
  attr :id, :string, default: nil
  slot :eyebrow
  slot :title, required: true
  slot :inner_block
  slot :actions

  def page_header(assigns) do
    ~H"""
    <header class="ui-page-header" id={@id}>
      <div class="ui-page-header-text">
        <p :if={@eyebrow != []} class="ui-eyebrow">{render_slot(@eyebrow)}</p>
        <h1 class="ui-page-title">{render_slot(@title)}</h1>
        <div :if={@inner_block != []} class="ui-page-lead">{render_slot(@inner_block)}</div>
      </div>
      <div :if={@actions != []} class="ui-page-actions">{render_slot(@actions)}</div>
    </header>
    """
  end

  @doc "A panel: a raised box with an optional head."
  attr :class, :any, default: nil
  attr :rest, :global
  slot :head
  slot :inner_block, required: true

  def panel(assigns) do
    ~H"""
    <section class={["ui-panel", @class]} {@rest}>
      <header :if={@head != []} class="ui-panel-head">{render_slot(@head)}</header>
      {render_slot(@inner_block)}
    </section>
    """
  end

  @doc "Segmented tabs that send `event` with the tab's id as `tab`."
  attr :tabs, :list, required: true, doc: "`{id, label}` pairs"
  attr :active, :string, required: true
  attr :event, :string, default: "tab"
  attr :label, :string, required: true

  def tabs(assigns) do
    ~H"""
    <div class="ui-tabs" role="tablist" aria-label={@label}>
      <button
        :for={{id, label} <- @tabs}
        type="button"
        role="tab"
        class="ui-tab"
        aria-selected={to_string(id == @active)}
        phx-click={@event}
        phx-value-tab={id}
      >
        {label}
      </button>
    </div>
    """
  end

  @doc "The window a surface is shown in: its id and version in the bar."
  attr :id, :string, required: true
  attr :surface_id, :string, required: true
  attr :version, :string, default: nil
  slot :inner_block, required: true

  def surface_frame(assigns) do
    ~H"""
    <article class="ui-frame" id={@id}>
      <header class="ui-frame-bar">
        <span class="ui-frame-dots" aria-hidden="true"><i></i><i></i><i></i></span>
        <span class="ui-frame-title"><span>surface</span>{@surface_id}</span>
        <.badge :if={@version} tone="neutral" class="ui-frame-version">{@version}</.badge>
      </header>
      <div class="ui-frame-body">{render_slot(@inner_block)}</div>
    </article>
    """
  end

  @doc "A dotted canvas that holds surfaces and what the agent says."
  attr :id, :string, default: nil
  attr :class, :any, default: nil
  slot :inner_block, required: true

  def canvas(assigns) do
    ~H"""
    <div class={["ui-canvas", @class]} id={@id}>{render_slot(@inner_block)}</div>
    """
  end

  @doc "A chat bubble: `user`, `agent` or `system`."
  attr :role, :string, required: true, values: ~w(user agent system)
  attr :id, :string, default: nil
  attr :rest, :global
  slot :inner_block, required: true

  def bubble(assigns) do
    ~H"""
    <div class={["ui-bubble", "ui-bubble-" <> @role]} id={@id} {@rest}>
      {render_slot(@inner_block)}
    </div>
    """
  end

  @doc "A callout: `info`, `warning` or `danger`, with an optional title."
  attr :tone, :string, default: "info", values: ~w(info warning danger)
  attr :title, :string, default: nil
  attr :class, :any, default: nil
  attr :rest, :global
  slot :inner_block

  def callout(assigns) do
    ~H"""
    <div class={["ui-callout", "ui-callout-" <> @tone, @class]} role="note" {@rest}>
      <.icon name={if @tone == "info", do: "info", else: "alert"} />
      <div class="ui-callout-body">
        <p :if={@title} class="ui-callout-title">{@title}</p>
        {render_slot(@inner_block)}
      </div>
    </div>
    """
  end

  @doc "What a place shows while it holds nothing."
  attr :rest, :global
  slot :inner_block, required: true

  def empty(assigns) do
    ~H"""
    <p class="ui-empty" {@rest}>{render_slot(@inner_block)}</p>
    """
  end

  @doc "JSON (or text with JSON in it), highlighted."
  attr :code, :string, required: true
  attr :class, :any, default: nil

  def code(assigns) do
    ~H"""
    <pre class={["ui-code", @class]}><code>{GalleryWeb.JSON.highlight(@code)}</code></pre>
    """
  end

  @doc """
  A message log: what went to and came from the agent, newest first. Each
  entry is a map with an `id`, a `direction` (`:in`, `:out`, `:effect`,
  `:user`), a `kind`, and optionally a `note` and the message as `json`.
  """
  attr :entries, :list, required: true
  attr :id, :string, required: true

  def message_log(assigns) do
    ~H"""
    <ol id={@id} class="ui-log">
      <li :for={entry <- @entries} id={"#{@id}-#{entry.id}"} class="ui-log-entry">
        <details :if={entry[:json]} phx-mounted={JS.ignore_attributes(["open"])}>
          <summary class="ui-log-head">
            <.log_head entry={entry} />
            <.icon name="chevron" class="ui-icon ui-log-chevron" />
          </summary>
          <.code code={entry.json} />
        </details>
        <div :if={!entry[:json]} class="ui-log-head"><.log_head entry={entry} /></div>
      </li>
    </ol>
    """
  end

  attr :entry, :map, required: true

  defp log_head(assigns) do
    ~H"""
    <span class={["ui-dir", "ui-dir-#{@entry.direction}"]}>{direction(@entry.direction)}</span>
    <span class="ui-log-kind">{@entry.kind}</span>
    <span :if={@entry[:note]} class="ui-log-note">{@entry.note}</span>
    """
  end

  defp direction(:in), do: "agent → renderer"
  defp direction(:out), do: "renderer → agent"
  defp direction(:effect), do: "renderer"
  defp direction(:user), do: "you"

  @doc "Pretty JSON for display."
  def pretty(value), do: Jason.encode!(value, pretty: true)
end

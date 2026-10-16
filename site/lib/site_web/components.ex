defmodule SiteWeb.Components do
  @moduledoc "The page's building blocks: icons, wireframes, section headings and code panels."

  use Phoenix.Component

  alias SiteWeb.Code

  @icons %{
    "core" =>
      ~S(<path d="M12 2.5 21 7v10l-9 4.5L3 17V7l9-4.5Z"/><path d="m3 7 9 4.5L21 7"/><path d="M12 11.5v10"/>),
    "protocol" =>
      ~S(<path d="M12 3 2.5 8 12 13l9.5-5L12 3Z"/><path d="M2.5 12.5 12 17.5l9.5-5"/><path d="M2.5 17 12 22l9.5-5"/>),
    "catalog" =>
      ~S(<rect x="3" y="3" width="7.5" height="7.5" rx="1.8"/><rect x="13.5" y="3" width="7.5" height="7.5" rx="1.8"/><rect x="3" y="13.5" width="7.5" height="7.5" rx="1.8"/><rect x="13.5" y="13.5" width="7.5" height="7.5" rx="3.75"/>),
    "data" =>
      ~S(<path d="M8 3H7a2 2 0 0 0-2 2v4a2 2 0 0 1-2 2 2 2 0 0 1 2 2v4a2 2 0 0 0 2 2h1"/><path d="M16 3h1a2 2 0 0 1 2 2v4a2 2 0 0 0 2 2 2 2 0 0 0-2 2v4a2 2 0 0 1-2 2h-1"/><circle cx="12" cy="12" r="1.3"/>),
    "render" =>
      ~S(<rect x="2.5" y="4" width="19" height="16" rx="2.5"/><path d="M2.5 9h19"/><path d="M9 9v11"/>),
    "rpc" =>
      ~S(<path d="M4 8h13"/><path d="m14 4 4 4-4 4"/><path d="M20 16H7"/><path d="m10 12-4 4 4 4"/>),
    "agent" =>
      ~S(<rect x="4" y="8" width="16" height="12" rx="3.5"/><path d="M12 4v4"/><circle cx="12" cy="3.4" r="1.1"/><path d="M9 14h.01M15 14h.01"/><path d="M2 13v3M22 13v3"/>),
    "transport" =>
      ~S(<circle cx="12" cy="12" r="2"/><path d="M8.2 15.8a5.4 5.4 0 0 1 0-7.6"/><path d="M15.8 8.2a5.4 5.4 0 0 1 0 7.6"/><path d="M5.3 18.7a9.5 9.5 0 0 1 0-13.4"/><path d="M18.7 5.3a9.5 9.5 0 0 1 0 13.4"/>),
    "mcp" =>
      ~S(<path d="M9 2.5v4.5"/><path d="M15 2.5v4.5"/><path d="M6 7h12v4a6 6 0 0 1-12 0V7Z"/><path d="M12 17v4.5"/>),
    "shield" =>
      ~S(<path d="M12 2.5 4 5.5v6c0 5 3.4 8.6 8 10 4.6-1.4 8-5 8-10v-6l-8-3Z"/><path d="m8.5 12 2.5 2.5 4.5-5"/>),
    "check" => ~S(<path d="m5 12.5 4.5 4.5L19 7.5"/>),
    "copy" =>
      ~S(<rect x="8" y="8" width="12" height="12" rx="2.5"/><path d="M16 8V6a2 2 0 0 0-2-2H6a2 2 0 0 0-2 2v8a2 2 0 0 0 2 2h2"/>),
    "sun" =>
      ~S(<circle cx="12" cy="12" r="4"/><path d="M12 2v2M12 20v2M4.9 4.9l1.4 1.4M17.7 17.7l1.4 1.4M2 12h2M20 12h2M4.9 19.1l1.4-1.4M17.7 6.3l1.4-1.4"/>),
    "moon" => ~S(<path d="M20.5 14.5A8.5 8.5 0 0 1 9.5 3.5a8.5 8.5 0 1 0 11 11Z"/>),
    "menu" => ~S(<path d="M4 7h16M4 12h16M4 17h16"/>),
    "terminal" =>
      ~S(<rect x="2.5" y="4" width="19" height="16" rx="2.5"/><path d="m7 9.5 3 2.5-3 2.5"/><path d="M12.5 15H17"/>),
    "arrow" => ~S(<path d="M5 12h14"/><path d="m13 6 6 6-6 6"/>),
    "replay" => ~S(<path d="M3.5 12a8.5 8.5 0 1 0 2.6-6.1"/><path d="M3.5 4v4.5H8"/>),
    "external" =>
      ~S(<path d="M14 4h6v6"/><path d="M20 4 11 13"/><path d="M18 14v5a1 1 0 0 1-1 1H5a1 1 0 0 1-1-1V7a1 1 0 0 1 1-1h5"/>),
    "sparkle" =>
      ~S(<path d="M12 3.5 13.9 9 19.5 11l-5.6 2-1.9 5.5-1.9-5.5L4.5 11l5.6-2L12 3.5Z"/><path d="M19 3v3M17.5 4.5h3"/>),
    "flask" =>
      ~S(<path d="M9 3h6"/><path d="M10 3v6L4.6 18.4A2 2 0 0 0 6.3 21.5h11.4a2 2 0 0 0 1.7-3.1L14 9V3"/><path d="M7.4 15h9.2"/>),
    "drop" =>
      ~S(<path d="M12 2.5c3.6 4.6 6.5 8.4 6.5 12a6.5 6.5 0 0 1-13 0c0-3.6 2.9-7.4 6.5-12Z"/>),
    "chat" =>
      ~S(<path d="M4 5.5A1.5 1.5 0 0 1 5.5 4h13A1.5 1.5 0 0 1 20 5.5v9a1.5 1.5 0 0 1-1.5 1.5H10l-4.5 3.8V16H5.5A1.5 1.5 0 0 1 4 14.5v-9Z"/><path d="M8 9h8M8 12h5"/>),
    "stream" => ~S(<path d="M4 6h9"/><path d="M4 10h14"/><path d="M4 14h7"/><path d="M4 18h11"/>),
    "form" =>
      ~S(<rect x="3.5" y="4" width="17" height="16" rx="2.5"/><path d="M7 8.5h6"/><rect x="7" y="11.5" width="10" height="3.5" rx="1"/><path d="M7 18h3"/>),
    "back" => ~S(<path d="m14.5 6-6 6 6 6"/>),
    "next" => ~S(<path d="m9.5 6 6 6-6 6"/>),
    "play" => ~S(<path d="M7.5 5v14l11-7-11-7Z"/>),
    "pause" => ~S(<path d="M8.5 5.5v13M15.5 5.5v13"/>)
  }

  @doc "The names of the available icons."
  def icon_names, do: Map.keys(@icons)

  @doc "A stroke icon, decorative unless given a label."
  attr :name, :string, required: true
  attr :class, :string, default: "icon"
  attr :label, :string, default: nil

  def icon(assigns) do
    assigns = assign(assigns, :paths, Map.fetch!(@icons, assigns.name))

    ~H"""
    <svg
      class={@class}
      viewBox="0 0 24 24"
      fill="none"
      stroke="currentColor"
      stroke-width="1.7"
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

  @doc "A section's numbered label and title, with the lead paragraph beside them."
  attr :id, :string, required: true
  attr :number, :string, required: true
  attr :eyebrow, :string, required: true
  slot :title, required: true
  slot :inner_block

  def section_heading(assigns) do
    ~H"""
    <header class="sec-head" data-reveal>
      <div class="sec-head-main">
        <p class="sec-label"><span class="sec-num">{@number}</span>{@eyebrow}</p>
        <h2 id={@id}>{render_slot(@title)}</h2>
      </div>
      <p :if={@inner_block != []} class="sec-lead">{render_slot(@inner_block)}</p>
    </header>
    """
  end

  @doc "Highlighted code in an editor window, with line numbers and a copy button."
  attr :code, :string, required: true
  attr :language, :atom, default: :elixir
  attr :title, :string, default: nil
  attr :class, :any, default: nil
  attr :numbers, :boolean, default: true
  attr :lang, :string, default: nil, doc: "the language's name, when not the highlighter's"
  attr :rest, :global

  def code_panel(assigns) do
    assigns = assign(assigns, :code, String.trim_trailing(assigns.code))

    ~H"""
    <figure class={["code-panel", @class]} {@rest}>
      <figcaption class="code-head">
        <span class="dots" aria-hidden="true"><i></i><i></i><i></i></span>
        <span :if={@title} class="code-title">{@title}</span>
        <span class="code-lang">{@lang || language_name(@language)}</span>
        <button type="button" class="copy" data-copy aria-label="Copy the code">
          <.icon name="copy" class="icon icon-xs" />
          <span data-copy-label>Copy</span>
        </button>
      </figcaption>
      <div class="code-body">
        <span :if={@numbers} class="gutter" aria-hidden="true">{gutter(@code)}</span>
        <pre><code>{Code.highlight(@code, @language)}</code></pre>
      </div>
    </figure>
    """
  end

  @doc "The line numbers of `code`, one per line."
  def gutter(code),
    do: code |> String.split("\n") |> Enum.with_index(1) |> Enum.map_join("\n", &elem(&1, 1))

  defp language_name(:elixir), do: "elixir"
  defp language_name(:json), do: "json"
  defp language_name(:shell), do: "shell"

  @doc "The project's mark: a drop holding lines of interface."
  attr :id, :string, required: true
  attr :class, :string, default: "logo"

  def logo(assigns) do
    ~H"""
    <svg class={@class} viewBox="0 0 32 32" aria-hidden="true">
      <defs>
        <linearGradient id={@id} x1="0" y1="0" x2="1" y2="1">
          <stop offset="0" stop-color="#8b5cf6" />
          <stop offset="0.55" stop-color="#6366f1" />
          <stop offset="1" stop-color="#06b6d4" />
        </linearGradient>
      </defs>
      <rect width="32" height="32" rx="9" fill={"url(#" <> @id <> ")"} />
      <path
        d="M16 6.5c3.4 4.3 6 7.9 6 11.3a6 6 0 0 1-12 0c0-3.4 2.6-7 6-11.3Z"
        fill="none"
        stroke="#fff"
        stroke-width="1.8"
        stroke-linejoin="round"
      />
      <path d="M13.2 17.6h5.6M13.2 20.6h3.6" stroke="#fff" stroke-width="1.8" stroke-linecap="round" />
    </svg>
    """
  end

  @doc """
  Escaped text with its `backquoted` spans as code.

      iex> SiteWeb.Components.rich("the `<a2ui>` tag") |> Phoenix.HTML.safe_to_string()
      "the <code>&lt;a2ui&gt;</code> tag"
  """
  def rich(text) when is_binary(text) do
    parts =
      text
      |> String.split("`")
      |> Enum.with_index(fn
        part, index when rem(index, 2) == 1 -> ["<code>", escape(part), "</code>"]
        part, _index -> escape(part)
      end)

    {:safe, parts}
  end

  defp escape(text), do: text |> Phoenix.HTML.html_escape() |> Phoenix.HTML.safe_to_string()

  @wireframes %{
    "Text" => ~S(<path d="M10 12h26" stroke-width="3"/><path d="M10 21h44M10 28h36"/>),
    "Image" =>
      ~S(<rect x="9" y="6" width="46" height="28" rx="3"/><path d="m13 30 11-11 8 8 6-6 13 9"/><circle cx="44" cy="14" r="3"/>),
    "Icon" =>
      ~S(<path d="M32 8.5 35.6 16l8.1 1.1-5.9 5.7 1.4 8.1-7.2-3.9-7.2 3.9 1.4-8.1-5.9-5.7 8.1-1.1Z"/>),
    "Video" =>
      ~S(<rect x="9" y="6" width="46" height="28" rx="3"/><path d="M28.5 14v12l9.5-6Z"/>),
    "AudioPlayer" =>
      ~S(<circle cx="15" cy="20" r="7"/><path d="M13.5 17v6l4.5-3Z"/><path d="M28 20h.01M32 15v10M36 11v18M40 16v8M44 13v14M48 17v6M52 15v10"/>),
    "Row" =>
      ~S(<rect x="6" y="12" width="15" height="16" rx="2"/><rect x="24.5" y="12" width="15" height="16" rx="2"/><rect x="43" y="12" width="15" height="16" rx="2"/>),
    "Column" =>
      ~S(<rect x="18" y="4" width="28" height="8" rx="2"/><rect x="18" y="16" width="28" height="8" rx="2"/><rect x="18" y="28" width="28" height="8" rx="2"/>),
    "List" =>
      ~S(<circle cx="13" cy="11" r="1.6"/><path d="M19 11h32"/><circle cx="13" cy="20" r="1.6"/><path d="M19 20h26"/><circle cx="13" cy="29" r="1.6"/><path d="M19 29h29"/>),
    "Card" =>
      ~S(<rect x="11" y="5" width="42" height="30" rx="4"/><path d="M17 13h18" stroke-width="2.4"/><path d="M17 20h30M17 26h22"/>),
    "Tabs" =>
      ~S(<path d="M7 34V15h50v19Z"/><path d="M9 15V9h14v6" stroke-width="2.2"/><path d="M26 15v-5h12v5M41 15v-5h12v5"/><path d="M13 22h26M13 28h18"/>),
    "Modal" =>
      ~S(<rect x="4" y="3" width="56" height="34" rx="3" stroke-dasharray="3 3"/><rect x="16" y="9" width="32" height="22" rx="3"/><path d="M21 15h14M21 21h22M37 26h6"/>),
    "Divider" =>
      ~S(<path d="M14 11h30M14 29h24" opacity=".45"/><path d="M8 20h48" stroke-width="2.2"/>),
    "Button" =>
      ~S(<rect x="12" y="12" width="40" height="16" rx="8"/><path d="M24 20h16" stroke-width="2.2"/>),
    "TextField" =>
      ~S(<path d="M9 9h14" opacity=".6"/><rect x="9" y="14" width="46" height="17" rx="3"/><path d="M15 18.5v8"/>),
    "CheckBox" =>
      ~S(<rect x="10" y="12" width="16" height="16" rx="3"/><path d="m13.8 20 3.1 3.1 5.6-6"/><path d="M32 20h22"/>),
    "ChoicePicker" =>
      ~S(<circle cx="14" cy="12" r="4.2"/><circle cx="14" cy="12" r="1.6" fill="currentColor"/><path d="M23 12h26"/><circle cx="14" cy="28" r="4.2"/><path d="M23 28h20"/>),
    "Slider" =>
      ~S(<path d="M8 20h48" opacity=".45"/><path d="M8 20h26" stroke-width="2.6"/><circle cx="34" cy="20" r="5"/>),
    "DateTimeInput" =>
      ~S(<rect x="18" y="8" width="28" height="26" rx="3"/><path d="M18 15h28M24 5v6M40 5v6"/><path d="M24 21h3M30.5 21h3M37 21h3M24 27h3M30.5 27h3"/>)
  }

  @doc "The names of the components that have a wireframe."
  def wireframe_names, do: Map.keys(@wireframes)

  @doc "A small line drawing of a basic catalog component."
  attr :name, :string, required: true

  def wireframe(assigns) do
    assigns = assign(assigns, :paths, Map.fetch!(@wireframes, assigns.name))

    ~H"""
    <svg
      class="wireframe"
      viewBox="0 0 64 40"
      fill="none"
      stroke="currentColor"
      stroke-width="1.5"
      stroke-linecap="round"
      stroke-linejoin="round"
      aria-hidden="true"
    >
      {Phoenix.HTML.raw(@paths)}
    </svg>
    """
  end

  @doc "A small tag naming a package."
  attr :name, :string, required: true

  def package_tag(assigns) do
    ~H"""
    <span class={["package-tag", "pkg-" <> @name]}>{@name}</span>
    """
  end
end

defmodule A2UIPhoenix.Components.Basic do
  @moduledoc """
  Function components for the basic catalog (v0.9.1 and v1.0): `Text`,
  `Image`, `Icon`, `Video`, `AudioPlayer`, `Row`, `Column`, `List`,
  `Card`, `Tabs`, `Modal`, `Divider`, `Button`, `TextField`, `CheckBox`,
  `ChoicePicker`, `Slider` and `DateTimeInput`.

  The markup and class names follow the reference web renderer
  (`a2ui-text`, `a2ui-button primary`, …) so its stylesheets apply. Inputs
  are named with `A2UIPhoenix.Context.input_name/2` and report changes
  through the surface's form; buttons, tabs, modals and chips send click
  events to the surface (`A2UIPhoenix.Surface`). Interactive elements use
  native controls and, where the control alone does not say it, the ARIA
  role from `A2UICore.Accessibility` (a `radiogroup` for a single-choice
  picker).

  `components/0` is the component map `A2UIPhoenix.Surface` starts from;
  a host overrides or extends it with its own `%{type => component}`.
  """

  use Phoenix.Component

  import A2UIPhoenix.Components,
    only: [child: 1, error_ids: 3, invalid?: 1, style: 1, style: 2, text: 1, validation_errors: 1]

  alias A2UIPhoenix.Context

  @moduledoc since: "0.1.0"

  @headings ~w(h1 h2 h3 h4 h5)

  @flex %{
    "start" => "flex-start",
    "center" => "center",
    "end" => "flex-end",
    "spaceBetween" => "space-between",
    "spaceAround" => "space-around",
    "spaceEvenly" => "space-evenly",
    "stretch" => "stretch",
    "baseline" => "baseline"
  }

  @icon_overrides %{
    "play" => "play_arrow",
    "rewind" => "fast_rewind",
    "favoriteOff" => "favorite_border",
    "starOff" => "star_border"
  }

  @doc "The basic catalog's components by type."
  @spec components() :: %{String.t() => (map() -> Phoenix.LiveView.Rendered.t())}
  def components do
    %{
      "Text" => &text_component/1,
      "Image" => &image/1,
      "Icon" => &icon/1,
      "Video" => &video/1,
      "AudioPlayer" => &audio_player/1,
      "Row" => &row/1,
      "Column" => &column/1,
      "List" => &list/1,
      "Card" => &card/1,
      "Tabs" => &tabs/1,
      "Modal" => &modal/1,
      "Divider" => &divider/1,
      "Button" => &button/1,
      "TextField" => &text_field/1,
      "CheckBox" => &check_box/1,
      "ChoicePicker" => &choice_picker/1,
      "Slider" => &slider/1,
      "DateTimeInput" => &date_time_input/1
    }
  end

  # -- display ------------------------------------------------------------------

  @doc "`Text`: a heading (v0.9 `h1`–`h5`), a caption, or body text."
  @spec text_component(map()) :: Phoenix.LiveView.Rendered.t()
  def text_component(assigns) do
    variant = assigns.props["variant"] || "body"
    assigns = assign(assigns, variant: variant, content: text(assigns.props["text"]))

    cond do
      variant in @headings ->
        ~H"""
        <span class={["a2ui-text", @variant]} style={style(@props)} {@attrs}><.dynamic_tag tag_name={@variant}>{@content}</.dynamic_tag></span>
        """

      variant == "caption" ->
        ~H"""
        <span class={["a2ui-text", @variant]} style={style(@props)} {@attrs}><em>{@content}</em></span>
        """

      assigns.ctx.markdown != nil ->
        ~H"""
        <span class={["a2ui-text", @variant]} style={style(@props)} {@attrs}>{@ctx.markdown.(@content)}</span>
        """

      true ->
        ~H"""
        <span class={["a2ui-text", @variant]} style={style(@props)} {@attrs}>{@content}</span>
        """
    end
  end

  @doc "`Image`."
  @spec image(map()) :: Phoenix.LiveView.Rendered.t()
  def image(assigns) do
    fit =
      if assigns.props["fit"] == "scaleDown",
        do: "scale-down",
        else: assigns.props["fit"] || "cover"

    assigns = assign(assigns, fit: fit, variant: assigns.props["variant"] || "default")

    ~H"""
    <img
      src={text(@props["url"])}
      alt={text(@props["description"])}
      class={["a2ui-image", @variant]}
      style={style(@props, ["object-fit: #{@fit}"])}
      {@attrs}
    />
    """
  end

  @doc "`Icon`: a Material Symbols ligature, or an SVG path (`{svgPath}`)."
  @spec icon(map()) :: Phoenix.LiveView.Rendered.t()
  def icon(assigns) do
    # An icon without a label is decorative.
    attrs =
      if assigns.attrs["aria-label"],
        do: Map.put(assigns.attrs, "role", "img"),
        else: Map.put(assigns.attrs, "aria-hidden", "true")

    assigns = assign(assigns, attrs: attrs, name: assigns.props["name"])

    ~H"""
    <%= case @name do %>
      <% %{"svgPath" => path} -> %>
        <svg class="a2ui-icon svg" viewBox="0 0 24 24" style={style(@props)} {@attrs}>
          <path d={path}></path>
        </svg>
      <% name -> %>
        <i class="material-icons a2ui-icon" style={style(@props)} {@attrs}>{icon_name(name)}</i>
    <% end %>
    """
  end

  @doc """
  The Material Symbols ligature of a catalog icon name.

      iex> A2UIPhoenix.Components.Basic.icon_name("arrowBack")
      "arrow_back"
      iex> A2UIPhoenix.Components.Basic.icon_name("play")
      "play_arrow"
  """
  @spec icon_name(term()) :: String.t()
  def icon_name(name) when is_binary(name) do
    Map.get_lazy(@icon_overrides, name, fn ->
      String.replace(name, ~r/[A-Z]/, &("_" <> String.downcase(&1)))
    end)
  end

  def icon_name(_name), do: ""

  @doc "`Video`."
  @spec video(map()) :: Phoenix.LiveView.Rendered.t()
  def video(assigns) do
    ~H"""
    <div class="a2ui-video-container" style={style(@props)} {@attrs}>
      <video src={@props["url"]} poster={@props["posterUrl"]} controls class="a2ui-video">
        Your browser does not support the video tag.
      </video>
    </div>
    """
  end

  @doc "`AudioPlayer`."
  @spec audio_player(map()) :: Phoenix.LiveView.Rendered.t()
  def audio_player(assigns) do
    ~H"""
    <div class="a2ui-audio-player" style={style(@props)} {@attrs}>
      <div :if={@props["description"] not in [nil, ""]} class="a2ui-audio-description">
        {text(@props["description"])}
      </div>
      <audio src={@props["url"]} controls class="a2ui-audio">
        Your browser does not support the audio tag.
      </audio>
    </div>
    """
  end

  @doc "`Divider`."
  @spec divider(map()) :: Phoenix.LiveView.Rendered.t()
  def divider(assigns) do
    assigns = assign(assigns, :axis, assigns.props["axis"] || "horizontal")

    ~H"""
    <hr
      class={["a2ui-divider", @axis]}
      aria-orientation={if @axis == "vertical", do: "vertical"}
      style={style(@props)}
      {@attrs}
    />
    """
  end

  # -- layout -------------------------------------------------------------------

  @doc "`Row`: children side by side."
  @spec row(map()) :: Phoenix.LiveView.Rendered.t()
  def row(assigns), do: flex(assign(assigns, :class, "a2ui-row"))

  @doc "`Column`: children stacked."
  @spec column(map()) :: Phoenix.LiveView.Rendered.t()
  def column(assigns), do: flex(assign(assigns, :class, "a2ui-column"))

  defp flex(assigns) do
    assigns =
      assign(assigns, :layout, [
        flex_declaration("justify-content", assigns.props["justify"]),
        flex_declaration("align-items", assigns.props["align"])
      ])

    ~H"""
    <div class={@class} style={style(@props, @layout)} {@attrs}>
      <.child ctx={@ctx} child={@props["children"]} />
    </div>
    """
  end

  defp flex_declaration(_property, nil), do: nil

  defp flex_declaration(property, value),
    do: "#{property}: #{Map.get(@flex, value, "flex-start")}"

  @doc "`List`: children in a scrolling list."
  @spec list(map()) :: Phoenix.LiveView.Rendered.t()
  def list(assigns) do
    assigns =
      assign(assigns,
        direction: assigns.props["direction"] || "vertical",
        children: List.wrap(assigns.props["children"])
      )

    ~H"""
    <div
      class={["a2ui-list", @direction]}
      style={style(@props, [flex_declaration("align-items", @props["align"])])}
      {@attrs}
    >
      <div :for={child <- @children} class="a2ui-list-item">
        <.child ctx={@ctx} child={child} />
      </div>
    </div>
    """
  end

  @doc "`Card`."
  @spec card(map()) :: Phoenix.LiveView.Rendered.t()
  def card(assigns) do
    ~H"""
    <div class="a2ui-card" style={style(@props)} {@attrs}>
      <.child ctx={@ctx} child={@props["child"]} />
    </div>
    """
  end

  @doc "`Tabs`: a tab bar and the open tab's content."
  @spec tabs(map()) :: Phoenix.LiveView.Rendered.t()
  def tabs(assigns) do
    tabs = Enum.filter(List.wrap(assigns.props["tabs"]), &is_map/1)
    active = Context.ui(assigns.ctx, assigns.node, :tab, 0)
    active = if active < length(tabs), do: active, else: 0

    assigns =
      assign(assigns, tabs: Enum.with_index(tabs), active: active, open: Enum.at(tabs, active))

    ~H"""
    <div class="a2ui-tabs" style={style(@props)} {@attrs}>
      <div class="a2ui-tab-bar" role="tablist">
        <button
          :for={{tab, index} <- @tabs}
          type="button"
          role="tab"
          id={Context.dom_id(@ctx, @node, "tab-#{index}")}
          aria-selected={to_string(index == @active)}
          aria-controls={Context.dom_id(@ctx, @node, "panel")}
          class={["a2ui-tab-button", index == @active && "active"]}
          phx-click="a2ui:tab"
          phx-value-ref={@node.ref}
          phx-value-index={index}
          phx-target={@ctx.target}
        >
          {text(tab["title"])}
        </button>
      </div>
      <div
        :if={@open}
        class="a2ui-tab-content"
        role="tabpanel"
        id={Context.dom_id(@ctx, @node, "panel")}
        aria-labelledby={Context.dom_id(@ctx, @node, "tab-#{@active}")}
      >
        <.child ctx={@ctx} child={@open["child"]} />
      </div>
    </div>
    """
  end

  @doc """
  `Modal`: the trigger, and the content in a dialog while it is open. A
  click on the trigger opens it — also when the trigger is a button with
  an action of its own.
  """
  @spec modal(map()) :: Phoenix.LiveView.Rendered.t()
  def modal(assigns) do
    assigns = assign(assigns, :open, Context.ui(assigns.ctx, assigns.node, :open, false))

    ~H"""
    <div class="a2ui-modal-wrapper" style={style(@props)} {@attrs}>
      <div
        class="a2ui-modal-trigger"
        phx-click="a2ui:modal"
        phx-value-ref={@node.ref}
        phx-value-open="true"
        phx-target={@ctx.target}
      >
        <.child ctx={@ctx} child={@props["trigger"]} />
      </div>
      <div :if={@open} class="a2ui-modal-overlay">
        <div
          class="a2ui-modal-content"
          role="dialog"
          aria-modal="true"
          id={Context.dom_id(@ctx, @node, "dialog")}
          phx-click-away="a2ui:modal"
          phx-window-keydown="a2ui:modal"
          phx-key="Escape"
          phx-value-ref={@node.ref}
          phx-value-open="false"
          phx-target={@ctx.target}
        >
          <button
            type="button"
            class="a2ui-modal-close"
            aria-label="Close"
            phx-click="a2ui:modal"
            phx-value-ref={@node.ref}
            phx-value-open="false"
            phx-target={@ctx.target}
          >
            &times;
          </button>
          <.child ctx={@ctx} child={@props["content"]} />
        </div>
      </div>
    </div>
    """
  end

  # -- input --------------------------------------------------------------------

  @doc "`Button`: invokes its `action`; disabled while its checks fail."
  @spec button(map()) :: Phoenix.LiveView.Rendered.t()
  def button(assigns) do
    assigns = assign(assigns, :variant, assigns.props["variant"] || "default")

    ~H"""
    <button
      type="button"
      class={["a2ui-button", @variant, "a2ui-button-#{@variant}"]}
      disabled={invalid?(@props)}
      phx-click="a2ui:action"
      phx-value-ref={@node.ref}
      phx-value-property="action"
      phx-target={@ctx.target}
      style={style(@props)}
      {@attrs}
    >
      <.child ctx={@ctx} child={@props["child"]} />
    </button>
    """
  end

  @doc "`TextField`: a text, number, password or multi-line input."
  @spec text_field(map()) :: Phoenix.LiveView.Rendered.t()
  def text_field(assigns) do
    type =
      case assigns.props["variant"] do
        "number" -> "number"
        "obscured" -> "password"
        _other -> "text"
      end

    assigns =
      assign(assigns,
        type: type,
        input_id: Context.dom_id(assigns.ctx, assigns.node, "input"),
        value: text(assigns.props["value"])
      )

    ~H"""
    <div class="a2ui-textfield-container" style={style(@props)} {@attrs}>
      <label :if={@props["label"] not in [nil, ""]} for={@input_id}>{text(@props["label"])}</label>
      <textarea
        :if={@props["variant"] == "longText"}
        id={@input_id}
        name={Context.input_name(@node)}
        class={["a2ui-textfield", invalid?(@props) && "invalid"]}
        placeholder={@props["placeholder"]}
        aria-invalid={if invalid?(@props), do: "true"}
        aria-describedby={error_ids(@ctx, @node, @props)}
      >{@value}</textarea>
      <input
        :if={@props["variant"] != "longText"}
        type={@type}
        id={@input_id}
        name={Context.input_name(@node)}
        value={@value}
        class={["a2ui-textfield", invalid?(@props) && "invalid"]}
        placeholder={@props["placeholder"]}
        aria-invalid={if invalid?(@props), do: "true"}
        aria-describedby={error_ids(@ctx, @node, @props)}
      />
      <.validation_errors ctx={@ctx} node={@node} props={@props} />
    </div>
    """
  end

  @doc "`CheckBox`."
  @spec check_box(map()) :: Phoenix.LiveView.Rendered.t()
  def check_box(assigns) do
    assigns = assign(assigns, :input_id, Context.dom_id(assigns.ctx, assigns.node, "input"))

    ~H"""
    <div class="a2ui-checkbox-container" style={style(@props)} {@attrs}>
      <label class={["a2ui-checkbox", invalid?(@props) && "invalid"]} for={@input_id}>
        <input type="hidden" name={Context.input_name(@node)} value="false" />
        <input
          type="checkbox"
          id={@input_id}
          name={Context.input_name(@node)}
          value="true"
          checked={@props["value"] == true}
          class={[invalid?(@props) && "invalid"]}
          aria-invalid={if invalid?(@props), do: "true"}
          aria-describedby={error_ids(@ctx, @node, @props)}
        />
        <span class="a2ui-check-box-text">{text(@props["label"])}</span>
      </label>
      <.validation_errors ctx={@ctx} node={@node} props={@props} />
    </div>
    """
  end

  @doc """
  `ChoicePicker`: radio buttons, checkboxes or chips over `options`,
  optionally with a filter.
  """
  @spec choice_picker(map()) :: Phoenix.LiveView.Rendered.t()
  def choice_picker(assigns) do
    props = assigns.props
    filter = Context.ui(assigns.ctx, assigns.node, :filter, "")

    options =
      for %{} = option <- List.wrap(props["options"]),
          props["filterable"] != true or filter == "" or
            String.contains?(String.downcase(text(option["label"])), String.downcase(filter)),
          do: option

    assigns =
      assign(assigns,
        multi?: props["variant"] == "multipleSelection",
        chips?: props["displayStyle"] == "chips",
        selected: selected(props["value"]),
        options: options,
        filter: filter,
        label_id: Context.dom_id(assigns.ctx, assigns.node, "label")
      )

    ~H"""
    <div class="a2ui-choice-picker-container" style={style(@props)} {@attrs}>
      <span :if={@props["label"] not in [nil, ""]} id={@label_id} class="a2ui-choice-picker-label">
        {text(@props["label"])}
      </span>
      <input
        :if={@props["filterable"] == true}
        type="text"
        class="filter-input"
        name={Context.input_name(@node, "filter")}
        value={@filter}
        placeholder="Filter options..."
        aria-label="Filter options"
      />
      <div
        class={[
          "a2ui-choice-picker",
          "options",
          if(@chips?, do: "chips a2ui-chips-group", else: "a2ui-options-group")
        ]}
        role={if @multi?, do: "group", else: "radiogroup"}
        aria-labelledby={if @props["label"] not in [nil, ""], do: @label_id}
        aria-invalid={if invalid?(@props), do: "true"}
        aria-describedby={error_ids(@ctx, @node, @props)}
      >
        <input
          :if={@multi? and not @chips?}
          type="hidden"
          name={Context.input_name(@node) <> "[]"}
          value=""
        />
        <%= for option <- @options do %>
          <button
            :if={@chips?}
            type="button"
            class={["a2ui-chip", "chip", option["value"] in @selected && "active selected"]}
            aria-pressed={to_string(option["value"] in @selected)}
            phx-click="a2ui:toggle"
            phx-value-ref={@node.ref}
            phx-value-option={option["value"]}
            phx-target={@ctx.target}
          >
            {text(option["label"])}
          </button>
          <label :if={not @chips?} class="a2ui-option-label">
            <input
              type={if @multi?, do: "checkbox", else: "radio"}
              name={if @multi?, do: Context.input_name(@node) <> "[]", else: Context.input_name(@node)}
              value={option["value"]}
              checked={option["value"] in @selected}
              class="a2ui-option-input"
            />
            <span class="a2ui-option-text">{text(option["label"])}</span>
          </label>
        <% end %>
      </div>
      <.validation_errors ctx={@ctx} node={@node} props={@props} />
    </div>
    """
  end

  defp selected(value) when is_list(value), do: value
  defp selected(value) when is_binary(value), do: [value]
  defp selected(_value), do: []

  @doc "`Slider`: a range input showing its value."
  @spec slider(map()) :: Phoenix.LiveView.Rendered.t()
  def slider(assigns) do
    props = assigns.props
    min = if is_number(props["min"]), do: props["min"], else: 0
    max = if is_number(props["max"]), do: props["max"], else: 100
    steps = props["steps"]
    step = if is_integer(steps) and steps > 0 and max > min, do: (max - min) / steps

    assigns =
      assign(assigns,
        min: min,
        max: max,
        step: step,
        input_id: Context.dom_id(assigns.ctx, assigns.node, "input")
      )

    ~H"""
    <div class="a2ui-slider-container" style={style(@props)} {@attrs}>
      <div class="a2ui-slider-header">
        <label class="a2ui-slider-label" for={@input_id}>{text(@props["label"])}</label>
        <span class="a2ui-slider-value">{text(@props["value"])}</span>
      </div>
      <input
        type="range"
        id={@input_id}
        name={Context.input_name(@node)}
        min={@min}
        max={@max}
        step={@step}
        value={text(@props["value"] || 0)}
        class="a2ui-slider"
        aria-invalid={if invalid?(@props), do: "true"}
        aria-describedby={error_ids(@ctx, @node, @props)}
      />
      <.validation_errors ctx={@ctx} node={@node} props={@props} />
    </div>
    """
  end

  @doc "`DateTimeInput`: a date input, a time input, or both."
  @spec date_time_input(map()) :: Phoenix.LiveView.Rendered.t()
  def date_time_input(assigns) do
    props = assigns.props
    raw = text(props["value"])

    assigns =
      assign(assigns,
        date?: props["enableDate"] != false,
        time?: props["enableTime"] == true,
        date: A2UIPhoenix.Inputs.date_part(raw),
        time: A2UIPhoenix.Inputs.time_part(raw),
        label_id: Context.dom_id(assigns.ctx, assigns.node, "label")
      )

    ~H"""
    <div class="a2ui-date-time-container" style={style(@props)} {@attrs}>
      <span :if={@props["label"] not in [nil, ""]} id={@label_id} class="a2ui-date-time-label">
        {text(@props["label"])}
      </span>
      <div class="a2ui-date-time-inputs">
        <input
          :if={@date?}
          type="date"
          name={Context.input_name(@node, "date")}
          value={@date}
          min={date_bound(@props["min"])}
          max={date_bound(@props["max"])}
          class="a2ui-date-time-input"
          aria-labelledby={if @props["label"] not in [nil, ""], do: @label_id}
          aria-invalid={if invalid?(@props), do: "true"}
        />
        <input
          :if={@time?}
          type="time"
          name={Context.input_name(@node, "time")}
          value={@time}
          class="a2ui-date-time-input"
          aria-labelledby={if @props["label"] not in [nil, ""], do: @label_id}
          aria-invalid={if invalid?(@props), do: "true"}
        />
      </div>
      <.validation_errors ctx={@ctx} node={@node} props={@props} />
    </div>
    """
  end

  defp date_bound(value) when is_binary(value) do
    case A2UIPhoenix.Inputs.date_part(value) do
      "" -> nil
      date -> date
    end
  end

  defp date_bound(_value), do: nil
end

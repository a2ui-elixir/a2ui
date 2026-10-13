defmodule A2UICore.Accessibility do
  @moduledoc """
  What a component tells assistive technology.

  The protocol guide ("Catalog-Agnostic Accessibility Requirements")
  asks catalogs and renderers to plumb the `accessibility` object of a
  component — `label`, `description`, `live`, `hidden` — into the
  platform's accessibility API, to infer sensible defaults from the
  component's visible text, and to let explicit attributes override what
  was inferred. `attributes/2` computes exactly that, from the component
  definition and the data it is bound to:

    * `label` — the explicit `accessibility.label`, else the first
      non-empty string among the component's `title`, `text` and `label`
      properties;
    * `description` — the explicit `accessibility.description`;
    * `live` — `"off"`, `"polite"` or `"assertive"` (`"off"` unless
      declared);
    * `hidden` — whether the component (and so its subtree) is hidden from
      assistive technology;
    * `role` and `checked` — for the basic catalog's interactive types:
      Button is a `"button"`, TextField a `"textbox"`, CheckBox a
      `"checkbox"` (with its state in `checked`) and ChoicePicker a
      `"radiogroup"`.

  `lint/1` is the catalog-side requirement: interactive components must
  declare some way to label them.

      iex> alias A2UICore.State.Component
      iex> button = Component.new("go", "Button", %{
      ...>   "title" => "Submit",
      ...>   "accessibility" => %{"label" => "Send form", "live" => "polite"}
      ...> })
      iex> {attributes, []} = A2UICore.Accessibility.attributes(button, A2UICore.Resolution.DataContext.new())
      iex> {attributes.label, attributes.live, attributes.hidden, attributes.role}
      {"Send form", "polite", false, "button"}
  """

  alias A2UICore.Catalog
  alias A2UICore.Resolution.DataContext
  alias A2UICore.State.Component

  @moduledoc since: "0.1.0"

  @type attributes :: %{
          label: String.t() | nil,
          description: String.t() | nil,
          live: String.t(),
          hidden: boolean(),
          role: String.t() | nil,
          checked: boolean() | nil
        }

  @typedoc "A catalog component that cannot be labelled."
  @type finding :: %{component: String.t(), reason: String.t()}

  @live_values ~w(off polite assertive)
  @label_sources ~w(title text label)
  @labelling_properties ~w(label title text child)

  @roles %{
    "Button" => "button",
    "TextField" => "textbox",
    "CheckBox" => "checkbox",
    "ChoicePicker" => "radiogroup"
  }

  # -- attributes -----------------------------------------------------------------

  @doc """
  The accessibility attributes of `component` in `context`.

  Dynamic values (`{"path": …}` / `{"@path": …}` bindings, function
  calls) are resolved against the context's data model; resolution
  warnings come back as effects.
  """
  @spec attributes(Component.t(), DataContext.t()) :: {attributes(), [DataContext.effect()]}
  def attributes(%Component{type: type, props: props}, %DataContext{} = context) do
    explicit = if is_map(props["accessibility"]), do: props["accessibility"], else: %{}

    {label, label_effects} = label(explicit, props, context)
    {description, description_effects} = string(context, explicit["description"])
    {hidden, hidden_effects} = DataContext.resolve_dynamic_value(context, explicit["hidden"])
    {checked, checked_effects} = checked(type, props, context)

    attributes = %{
      label: label,
      description: description,
      live: live(explicit["live"]),
      hidden: hidden == true,
      role: Map.get(@roles, type),
      checked: checked
    }

    {attributes, label_effects ++ description_effects ++ hidden_effects ++ checked_effects}
  end

  defp label(explicit, props, context) do
    case string(context, explicit["label"]) do
      {label, effects} when is_binary(label) -> {label, effects}
      {nil, effects} -> inferred_label(props, context, effects)
    end
  end

  defp inferred_label(props, context, effects) do
    Enum.reduce_while(@label_sources, {nil, effects}, fn key, {nil, effects} ->
      case string(context, props[key]) do
        {text, more} when is_binary(text) and text != "" -> {:halt, {text, effects ++ more}}
        {_none, more} -> {:cont, {nil, effects ++ more}}
      end
    end)
  end

  defp string(context, raw) do
    case DataContext.resolve_dynamic_value(context, raw) do
      {value, effects} when is_binary(value) -> {value, effects}
      {_other, effects} -> {nil, effects}
    end
  end

  defp live(value) when value in @live_values, do: value
  defp live(_value), do: "off"

  defp checked("CheckBox", props, context) do
    raw = if Map.has_key?(props, "value"), do: props["value"], else: props["checked"]

    case DataContext.resolve_dynamic_value(context, raw) do
      {value, effects} when is_boolean(value) -> {value, effects}
      {_other, effects} -> {nil, effects}
    end
  end

  defp checked(_type, _props, _context), do: {nil, []}

  # -- catalog lint ---------------------------------------------------------------

  @doc """
  Checks a catalog against the requirement that components accepting
  actions or input bindings declare how they are labelled.

  A component is interactive when one of its properties is an `Action`
  or when it has a `value` property bound to a dynamic type. It is
  labellable when it declares a `label`, `title`, `text` or `child`
  property (required or not — an optional one is a fallback). Every
  component carries `accessibility` from the component envelope, so an
  explicit label is always possible; this checks that the catalog itself
  gives the component a visible one to fall back on.

  Returns a list of findings; an empty list means the catalog conforms.
  """
  @spec lint(Catalog.t()) :: [finding()]
  def lint(%Catalog{components: components}) do
    components
    |> Enum.sort()
    |> Enum.flat_map(fn {type, component} ->
      properties = properties(component.schema)

      if interactive?(properties) and not labellable?(properties) do
        [
          %{
            component: type,
            reason:
              "accepts actions or input bindings but declares none of " <>
                Enum.join(@labelling_properties, ", ") <> " to label it"
          }
        ]
      else
        []
      end
    end)
  end

  defp interactive?(properties) do
    Enum.any?(properties, fn {name, schema} ->
      ref = reference(schema)
      String.ends_with?(ref, "/Action") or (name == "value" and dynamic?(ref))
    end)
  end

  defp labellable?(properties),
    do: Enum.any?(@labelling_properties, &Map.has_key?(properties, &1))

  defp dynamic?(ref), do: ref |> Path.basename() |> String.starts_with?("Dynamic")

  defp reference(%{"$ref" => ref}) when is_binary(ref), do: ref
  defp reference(_schema), do: ""

  # The component's own properties, whether declared at the top of its
  # schema or in the members of an `allOf`.
  defp properties(schema) when is_map(schema) do
    own = if is_map(schema["properties"]), do: schema["properties"], else: %{}

    schema
    |> Map.get("allOf", [])
    |> Enum.reduce(own, &Map.merge(&2, properties(&1)))
  end

  defp properties(_schema), do: %{}
end

defmodule A2UIAgent.Builder.Basic do
  @moduledoc """
  A function for each component of the basic catalog, named after it in
  snake case: `text/1`, `text_field/1`, `date_time_input/1` and so on.
  Each one is `A2UIAgent.Builder.component/2` with the component's name.

      iex> import A2UIAgent.Builder.Basic
      iex> text(text: "Hello", variant: "caption")
      %A2UIAgent.Builder.Component{component: "Text", props: [{"text", "Hello"}, {"variant", "caption"}]}

  The basic catalogs of protocol v0.9 and v1.0 have the same components;
  their properties differ a little. Pass the catalog you write for to
  `A2UIAgent.Builder.flatten/2` (`:catalog`) to fill in its defaults and
  check each component against it.
  """

  alias A2UIAgent.Builder
  alias A2UIAgent.Builder.Component

  @moduledoc since: "0.1.0"

  @components ~w(Text Image Icon Video AudioPlayer Row Column List Card Tabs Modal Divider
                 Button TextField CheckBox ChoicePicker Slider DateTimeInput)

  @doc "The names of the basic catalog's components, in catalog order."
  @spec components() :: [String.t()]
  def components, do: @components

  for name <- @components do
    function = name |> Macro.underscore() |> String.to_atom()

    @doc "A `#{name}` component; see `A2UIAgent.Builder.component/2`."
    @spec unquote(function)(Builder.props()) :: Component.t()
    def unquote(function)(props \\ []), do: Builder.component(unquote(name), props)
  end
end

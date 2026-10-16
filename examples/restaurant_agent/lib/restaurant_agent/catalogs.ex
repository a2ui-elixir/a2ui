defmodule RestaurantAgent.Catalogs do
  @moduledoc """
  The catalogs the agent writes for, and the generators that negotiate
  them with each renderer.

    * protocol v1.0: the basic catalog, narrowed to the components the
      agent uses and extended with the `RestaurantCard` macro, next to the
      restaurant catalog (`examples/catalogs/restaurant_catalog.json`:
      the `Rating` component and the `checkAvailability` and
      `clientInfo` functions);
    * protocol v0.9: the basic catalog alone.

  A renderer that supports both gets v1.0, the first generator.
  """

  import A2UIAgent.Builder, only: [call: 2]
  import A2UIAgent.Builder.Basic

  alias A2UIAgent.{CatalogConfig, CatalogTransformer, Generator, Macro, MacroExpander}
  alias A2UIAgent.Builder.Binding
  alias A2UICore.Catalog
  alias A2UICore.Catalog.Basic

  @restaurant_path Path.expand("../../../catalogs/restaurant_catalog.json", __DIR__)
  @external_resource @restaurant_path
  @restaurant_document File.read!(@restaurant_path)

  @components ~w(Column Row Card List Text Image Icon Button Divider TextField
                 DateTimeInput Slider ChoicePicker)

  @doc "The id of the restaurant catalog."
  @spec restaurant_id() :: String.t()
  def restaurant_id, do: restaurant().catalog_id

  @doc "The restaurant catalog, read with its key order kept (for Express)."
  @spec restaurant() :: Catalog.t()
  def restaurant do
    @restaurant_document
    |> Jason.decode!(objects: :ordered_objects)
    |> Catalog.from_json!()
  end

  @doc "The basic catalog of `version`, without implementations: all an agent needs."
  @spec basic(String.t()) :: Catalog.t()
  def basic(version), do: Basic.declared(version)

  @doc """
  The `RestaurantCard` macro: one restaurant of a list. The model writes
  one component; the agent expands it into a card for a horizontal list:
  the picture, the name with the details under it, a `Rating` the model
  writes next to it, and a Book button at the bottom.
  """
  @spec restaurant_card() :: Macro.t()
  def restaurant_card do
    Macro.new(
      "RestaurantCard",
      [
        name: [type: :dynamic_string, description: "The restaurant's name."],
        image: [type: :dynamic_string, description: "The URL of its picture."],
        dish: [type: :dynamic_string, description: "What the picture shows, for screen readers."],
        details: [type: :dynamic_string, description: "Cuisine, price range and distance."],
        rating: [type: :component, description: "The id of a Rating component."],
        action: [type: :action, description: "What the Book a table button does."]
      ],
      fn args ->
        card(
          child:
            column(
              justify: "spaceBetween",
              children: [
                column(
                  children: [
                    image(
                      url: args.image,
                      description: args.dish,
                      fit: "cover",
                      variant: "mediumFeature"
                    ),
                    text(text: heading(args.name)),
                    text(text: args.details, variant: "caption"),
                    args.rating
                  ]
                ),
                button(child: text(text: "Book a table"), action: args.action)
              ]
            )
        )
      end,
      description: "A restaurant in a list: picture, name, details, rating and a Book button."
    )
  end

  # The name as a Markdown heading: protocol v1.0 has no heading variants.
  defp heading(%Binding{path: path}), do: call("formatString", value: "#### ${#{path}}")
  defp heading(name) when is_binary(name), do: "#### " <> name
  defp heading(name), do: name

  @doc "The expander of the agent's macros over the v1.0 basic catalog."
  @spec expander() :: MacroExpander.t()
  def expander, do: MacroExpander.new(basic("v1.0"), [restaurant_card()])

  @doc "The catalog the model writes for in v1.0: the basic catalog and the macros."
  @spec inference_catalog() :: Catalog.t()
  def inference_catalog do
    {:ok, catalog} = MacroExpander.inference_catalog(expander())
    catalog
  end

  @doc """
  The generators, v1.0 first. Options: `:format` (`A2UIAgent.DirectJson`
  by default, or `A2UIAgent.Express`).

  Express names a surface's default catalog only when the agent writes
  for a single catalog. With several, its surfaces have none, and the
  function calls inside `formatString` templates could not name theirs,
  so Express writes for the basic catalog alone.
  """
  @spec generators(keyword()) :: [Generator.t()]
  def generators(options \\ []) do
    format = Keyword.get(options, :format, A2UIAgent.DirectJson)
    pruning = CatalogTransformer.component_pruning(@components ++ ["RestaurantCard"])

    v1_catalogs =
      if format == A2UIAgent.Express,
        do: [CatalogConfig.new(basic("v1.0"), transformers: [pruning])],
        else: [
          CatalogConfig.new(inference_catalog(), transformers: [pruning]),
          CatalogConfig.new(restaurant())
        ]

    v1 = Generator.new(v1_catalogs, format: format, examples: examples(format))

    v09 =
      Generator.new([CatalogConfig.new(basic("v0.9.1"), transformers: [pruning])], format: format)

    [v1, v09]
  end

  # The few-shot example of the prompt: a list of restaurants, written
  # with the macro.
  defp examples(A2UIAgent.DirectJson), do: [RestaurantAgent.Model.example()]
  defp examples(_format), do: []
end

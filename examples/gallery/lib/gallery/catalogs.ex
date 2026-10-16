defmodule Gallery.Catalogs do
  @moduledoc """
  The catalogs the gallery renders with: the basic catalogs (with their
  functions), the restaurant catalog shared by the examples (whose
  `clientInfo` function the gallery implements; `checkAvailability`
  belongs to the agent), and the MCP catalog.
  """

  alias A2UICore.Catalog

  @restaurant_path Path.expand("../../../catalogs/restaurant_catalog.json", __DIR__)
  @external_resource @restaurant_path
  @restaurant_document File.read!(@restaurant_path)

  @doc "The basic catalog of `version` (`\"v1.0\"` or `\"v0.9.1\"`)."
  def basic(version), do: Catalog.Basic.catalog(version)

  @doc "The id of the basic catalog of `version`."
  def basic_id(version \\ "v1.0"), do: basic(version).catalog_id

  @doc "The restaurant catalog, with this renderer's `clientInfo`."
  def restaurant do
    @restaurant_document
    |> Jason.decode!(objects: :ordered_objects)
    |> Catalog.from_json!()
    |> Catalog.put_implementations(%{"clientInfo" => &client_info/2})
  end

  @doc "The id of the restaurant catalog."
  def restaurant_id, do: "https://example.com/a2ui/catalogs/restaurant/v1/catalog.json"

  defp client_info(_args, _context) do
    {:ok,
     %{
       "renderer" => "A2UI gallery (Phoenix LiveView)",
       "locale" => "en-US",
       "timeZone" => time_zone()
     }}
  end

  defp time_zone, do: System.get_env("TZ") || "Etc/UTC"

  @widgets_path Path.expand("../../priv/catalogs/widgets_catalog.json", __DIR__)
  @external_resource @widgets_path
  @widgets_document File.read!(@widgets_path)

  @doc """
  The gallery's own catalog (`priv/catalogs/widgets_catalog.json`): the
  components `Badge`, `Progress` and `Panel`, drawn by
  `GalleryWeb.WidgetComponents`, and the function `initials`.
  """
  def widgets do
    @widgets_document
    |> Jason.decode!(objects: :ordered_objects)
    |> Catalog.from_json!()
    |> Catalog.put_implementations(%{"initials" => &initials/2})
  end

  @doc "The id of the gallery's own catalog."
  def widgets_id, do: "https://example.com/a2ui/catalogs/widgets/v1/catalog.json"

  defp initials(%{"name" => name}, _context) do
    initials =
      name
      |> to_string()
      |> String.split(~r/[\s-]+/u, trim: true)
      |> Enum.map_join(&(&1 |> String.first() |> String.upcase()))

    {:ok, initials}
  end

  @doc "The MCP catalog, calling tools through `client`."
  def mcp(client), do: Catalog.MCP.catalog("v1.0", client: client)
end

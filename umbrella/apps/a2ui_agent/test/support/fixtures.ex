defmodule A2UIAgent.Test.Fixtures do
  @moduledoc false
  # Catalogs and messages shared by the agent tests.

  alias A2UICore.Catalog
  alias A2UICore.Schema.Source

  @basic_id "https://a2ui.org/specification/v1_0/catalogs/basic/catalog.json"

  def basic_id, do: @basic_id

  def basic, do: Catalog.from_json!(Source.catalog("v1.0", :basic))

  def basic_v09,
    do: Catalog.from_json!(Source.catalog("v0.9.1", :basic), protocol_version: "v0.9.1")

  # A small catalog whose components are objects with an optional string
  # `text`.
  def catalog(id, names, version \\ "v1.0") do
    Catalog.from_json!(%{
      "catalogId" => id,
      "protocolVersion" => version,
      "components" =>
        Map.new(names, fn name ->
          {name, %{"type" => "object", "properties" => %{"text" => %{"type" => "string"}}}}
        end)
    })
  end

  def create(surface_id \\ "s1", catalog_id \\ @basic_id, version \\ "v1.0") do
    %{
      "version" => version,
      "createSurface" => %{"surfaceId" => surface_id, "catalogId" => catalog_id}
    }
  end

  def update(components, surface_id \\ "s1", version \\ "v1.0") do
    %{
      "version" => version,
      "updateComponents" => %{"surfaceId" => surface_id, "components" => components}
    }
  end

  def delete(surface_id \\ "s1", version \\ "v1.0"),
    do: %{"version" => version, "deleteSurface" => %{"surfaceId" => surface_id}}

  def text(id, text), do: %{"id" => id, "component" => "Text", "text" => text}

  # A complete surface: created, with a root Text.
  def surface(surface_id \\ "s1", text \\ "Hello"),
    do: [create(surface_id), update([text("root", text)], surface_id)]
end

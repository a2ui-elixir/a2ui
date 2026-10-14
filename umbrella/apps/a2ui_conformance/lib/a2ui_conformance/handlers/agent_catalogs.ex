defmodule A2UIConformance.Handlers.AgentCatalogs do
  @moduledoc false

  # `provide_catalog`, `transform_catalog` and `resolve_catalogs`
  # (reference python/a2ui_agent/tests/conformance/test_catalog_conformance.py).
  #
  #   * provide_catalog: load `args.path` (file system provider, the
  #     default) or `args.catalog` (in-memory) with the optional
  #     `catalog_id` / `protocol_version`, then check the catalog;
  #   * transform_catalog: register `args.catalog` with its
  #     `transformers` and check the transformed catalog;
  #   * resolve_catalogs: resolve `args.catalogs` against
  #     `args.renderer_capabilities`; active ids compare as sorted lists,
  #     and each `expect.catalogs` entry is checked by id.

  @behaviour A2UIConformance.Handler

  import ExUnit.Assertions

  alias A2UIAgent.{CatalogProvider, CatalogResolver}
  alias A2UIConformance.{AgentFixtures, Case}

  @impl true
  def run(%Case{action: "provide_catalog", raw: raw}, _context) do
    args = raw["args"]
    options = [catalog_id: args["catalog_id"], protocol_version: args["protocol_version"]]

    provide = fn ->
      case args["provider"] || "file_system" do
        "file_system" -> CatalogProvider.load_file(AgentFixtures.path(args["path"]), options)
        "in_memory" -> CatalogProvider.load_document(args["catalog"], options)
      end
    end

    case raw do
      %{"expect_error" => expected} ->
        AgentFixtures.expect_error(expected, provide)

      %{"expect" => expected} ->
        assert {:ok, catalog} = provide.()
        AgentFixtures.expect_catalog(catalog, expected)
    end
  end

  def run(%Case{action: "transform_catalog", raw: raw}, _context) do
    config = AgentFixtures.catalog_config(raw["args"])
    AgentFixtures.expect_catalog(config.transformed, raw["expect"])
  end

  def run(%Case{action: "resolve_catalogs", raw: raw}, _context) do
    args = raw["args"]

    resolve = fn ->
      args["catalogs"]
      |> Enum.map(&AgentFixtures.catalog_config/1)
      |> CatalogResolver.resolve(args["renderer_capabilities"],
        accepts_inline_catalogs: args["accepts_inline_catalogs"] == true
      )
    end

    case raw do
      %{"expect_error" => expected} ->
        AgentFixtures.expect_error(expected, resolve)

      %{"expect" => expected} ->
        assert {:ok, catalogs} = resolve.()
        ids = Enum.map(catalogs, & &1.catalog_id)
        assert Enum.sort(ids) == Enum.sort(expected["active_catalog_ids"])
        by_id = Map.new(catalogs, &{&1.catalog_id, &1})

        Enum.each(expected["catalogs"] || [], fn wanted ->
          AgentFixtures.expect_catalog(Map.fetch!(by_id, wanted["catalog_id"]), wanted)
        end)
    end
  end
end

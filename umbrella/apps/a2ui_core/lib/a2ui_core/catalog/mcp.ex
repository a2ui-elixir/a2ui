defmodule A2UICore.Catalog.MCP do
  @moduledoc """
  The A2UI MCP catalog, ready to evaluate: the catalog through which a
  surface calls [Model Context Protocol](https://modelcontextprotocol.io)
  tools.

    * v0.9 (`https://a2ui.org/specification/v0_9/catalogs/mcp/mcp_catalog.json`)
      declares the functions `callMcpTool`, `jmespath`, `split`,
      `regexCapture`, `regexReplace` and `updateDataModel`, and no
      components.
    * v1.0 (`https://a2ui.org/specification/v1_0/catalogs/mcp/catalog.json`)
      declares `callMcpTool` (with `targetDataPath`) and the `McpApp`
      component, which renders an MCP App in a sandbox.

  The catalog documents are the vendored published ones
  (`A2UICore.Schema.Source.catalog/2`); the functions get their
  implementations from `A2UICore.Functions.MCP`. A renderer serves the
  catalog next to the basic one: in v1.0 a call or a component names it
  by `catalogId`; in v0.9 a surface has one catalog, so the MCP functions
  join the basic catalog's in a catalog of the host's own (see
  `A2UICore.Catalog.copy_with/2`).
  """

  alias A2UICore.Catalog
  alias A2UICore.Functions
  alias A2UICore.Schema.Source

  @moduledoc since: "0.1.0"

  @doc """
  The MCP catalog for `version` (`"v0.9"`, `"v0.9.1"` or `"v1.0"`), with
  its functions implemented.

  Options: `:client` — the MCP client `callMcpTool` uses (see
  `A2UICore.Functions.MCP.implementations/2`).
  """
  @spec catalog(String.t(), keyword()) :: Catalog.t()
  def catalog(version, options \\ []),
    do: version |> declared() |> implement(version, options)

  @doc """
  The MCP catalog for `version` as published: function and component
  schemas, no implementations.
  """
  @spec declared(String.t()) :: Catalog.t()
  def declared(version) do
    key = {__MODULE__, version}

    case :persistent_term.get(key, :missing) do
      :missing ->
        catalog =
          version
          |> Source.ordered_catalog(:mcp)
          |> Catalog.from_json!(protocol_version: version)

        :persistent_term.put(key, catalog)
        catalog

      catalog ->
        catalog
    end
  end

  @doc """
  Attaches the MCP functions' implementations and the system functions of
  `version` to a catalog that declares them (the MCP catalog, or one that
  copies its functions). Functions the catalog does not declare are
  ignored.

  Options: as for `catalog/2`.
  """
  @spec implement(Catalog.t(), String.t(), keyword()) :: Catalog.t()
  def implement(%Catalog{} = catalog, version, options \\ []) do
    catalog
    |> Catalog.put_implementations(Functions.MCP.implementations(version, options))
    |> Catalog.put_system_functions(Functions.System.functions(version))
  end

  @doc """
  The catalog ID of the MCP catalog for `version`.

      iex> A2UICore.Catalog.MCP.catalog_id("v1.0")
      "https://a2ui.org/specification/v1_0/catalogs/mcp/catalog.json"
  """
  @spec catalog_id(String.t()) :: String.t()
  def catalog_id(version), do: declared(version).catalog_id
end

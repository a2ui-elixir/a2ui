defmodule A2UICore.Catalog.Basic do
  @moduledoc """
  The basic catalog of a protocol version, ready to evaluate.

  The catalog document is the vendored published one
  (`A2UICore.Schema.Source.catalog/2`); the functions it declares get
  their implementations from `A2UICore.Functions.Basic`, plus the
  runtime's system functions (`@index` in v1.0).

  `declared/1` is the catalog without implementations — the schema an
  agent works with. Only that data is cached; `catalog/2` attaches the
  implementations on every call, so no closures outlive a code reload.
  """

  alias A2UICore.Catalog
  alias A2UICore.Functions
  alias A2UICore.Schema.Source

  @moduledoc since: "0.1.0"

  @doc """
  The basic catalog for `version` (`"v0.9"`, `"v0.9.1"` or `"v1.0"`),
  with its functions implemented.

  Options: `:formatter` — an `A2UICore.Formatter` module for the
  locale-sensitive functions.
  """
  @spec catalog(String.t(), keyword()) :: Catalog.t()
  def catalog(version, options \\ []),
    do: version |> declared() |> implement(version, options)

  @doc """
  The basic catalog for `version` as published: components and function
  schemas, no implementations.
  """
  @spec declared(String.t()) :: Catalog.t()
  def declared(version) do
    key = {__MODULE__, version}

    case :persistent_term.get(key, :missing) do
      :missing ->
        catalog =
          version
          |> Source.catalog(:basic)
          |> Catalog.from_json!(protocol_version: version)

        :persistent_term.put(key, catalog)
        catalog

      catalog ->
        catalog
    end
  end

  @doc """
  Attaches the basic functions' implementations and the system functions
  of `version` to a catalog that declares them (the basic catalog, or one
  derived from it). Functions the catalog does not declare are ignored.

  Options: as for `catalog/2`.
  """
  @spec implement(Catalog.t(), String.t(), keyword()) :: Catalog.t()
  def implement(%Catalog{} = catalog, version, options \\ []) do
    catalog =
      Catalog.put_implementations(catalog, Functions.Basic.implementations(version, options))

    system = Map.new(Functions.System.functions(version), &{&1.name, &1})

    %{catalog | functions: Map.merge(catalog.functions, system)}
  end
end

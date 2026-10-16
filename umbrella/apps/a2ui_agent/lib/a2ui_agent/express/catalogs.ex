defmodule A2UIAgent.Express.Catalogs do
  @moduledoc """
  The active catalogs of an Express format, compiler or decompiler, with
  a schema helper for each, and the lookups they share.

  The catalogs must be non-empty, have distinct ids and target one
  protocol version; several catalogs need v1.0 or later, where each
  component and function call carries its own `catalogId`. With one
  catalog, a surface is bound to it and nothing in Express names it.
  With several, a surface has no catalog: a name is looked up across the
  catalogs, and one that several catalogs define needs a `catalogId`.
  """

  alias A2UIAgent.Catalogs, as: Check
  alias A2UIAgent.Express.{Failure, SchemaHelper}
  alias A2UICore.{Catalog, Error, SemVer, Version}

  @moduledoc since: "0.1.0"

  defstruct catalogs: [], helpers: [], version: nil

  @type t :: %__MODULE__{
          catalogs: [Catalog.t()],
          helpers: [SchemaHelper.t()],
          version: String.t()
        }

  @typedoc "Whether a name is a component or a function."
  @type kind :: :component | :function

  @doc """
  Checks `catalogs` and builds their helpers for `version` (default: the
  catalogs' protocol version). A version must be on the catalogs'
  release line (`v0.9` and `v0.9.1` are one line).
  """
  @spec new([Catalog.t()], String.t() | nil) :: {:ok, t()} | {:error, Error.t()}
  def new(catalogs, version \\ nil) do
    with {:ok, catalogs} <- Check.check(catalogs),
         :ok <- check_mixed(catalogs),
         {:ok, version} <- target_version(catalogs, version) do
      {:ok,
       %__MODULE__{
         catalogs: catalogs,
         helpers: SchemaHelper.build_all(catalogs, version),
         version: version
       }}
    end
  end

  defp check_mixed([first, _second | _]) do
    version = Check.protocol_version(first)

    if SemVer.at_least(version, "v1.0"),
      do: :ok,
      else:
        {:error,
         catalog_error(
           "Several catalogs need A2UI v1.0 or later, but the catalogs target #{version}."
         )}
  end

  defp check_mixed(_catalogs), do: :ok

  defp target_version([first | _], nil), do: {:ok, Check.protocol_version(first)}

  defp target_version([first | _], requested) do
    catalog_version = Check.protocol_version(first)

    with {:ok, version} <- Version.to_protocol_version(requested),
         true <- line(version) == line(catalog_version) do
      {:ok, version}
    else
      _mismatch ->
        {:error,
         catalog_error(
           "Requested protocol version '#{requested}' does not match catalog version " <>
             "'#{catalog_version}'"
         )}
    end
  end

  defp line(version), do: version |> String.split(".") |> Enum.take(2) |> Enum.join(".")

  defp catalog_error(message), do: Error.new(:catalog, "CATALOG_ERROR", message)

  @doc "The helper of the catalog with id `catalog_id`, or `nil`."
  @spec helper(t(), term()) :: SchemaHelper.t() | nil
  def helper(%__MODULE__{helpers: helpers}, catalog_id),
    do: Enum.find(helpers, &(&1.catalog_id == catalog_id))

  @doc "The first catalog's helper."
  @spec first_helper(t()) :: SchemaHelper.t()
  def first_helper(%__MODULE__{helpers: [first | _]}), do: first

  @doc "The id of the only catalog, or `nil` when there are several."
  @spec sole_catalog_id(t()) :: String.t() | nil
  def sole_catalog_id(%__MODULE__{catalogs: [only]}), do: only.catalog_id
  def sole_catalog_id(%__MODULE__{}), do: nil

  @doc "The ids of the catalogs that define a component or function, in catalog order."
  @spec defining(t(), kind(), String.t()) :: [String.t()]
  def defining(%__MODULE__{helpers: helpers}, kind, name),
    do: for(helper <- helpers, defines?(helper, kind, name), do: helper.catalog_id)

  @doc "Whether `helper`'s catalog defines a component or function."
  @spec defines?(SchemaHelper.t(), kind(), String.t()) :: boolean()
  def defines?(helper, :component, name), do: SchemaHelper.component?(helper, name)
  def defines?(helper, :function, name), do: SchemaHelper.function?(helper, name)

  @doc """
  Whether the protocol version is at least v1.0, where components and
  calls carry their own `catalogId`.
  """
  @spec v1?(String.t()) :: boolean()
  def v1?(version), do: SemVer.at_least(version, "v1.0")

  @doc false
  @spec unknown_catalog!(t(), String.t(), term()) :: no_return()
  def unknown_catalog!(%__MODULE__{catalogs: catalogs}, target, catalog_id) do
    active = Enum.map_join(catalogs, ", ", &"'#{&1.catalog_id}'")

    Failure.validation!(
      "#{target} targets unknown catalog '#{catalog_id}'. Active catalogs: #{active}."
    )
  end

  @doc false
  @spec unknown_symbol!(t(), kind(), String.t(), String.t() | nil) :: no_return()
  def unknown_symbol!(%__MODULE__{} = catalogs, kind, name, catalog_id) do
    label = label(kind)

    case defining(catalogs, kind, name) do
      [] ->
        Failure.validation!("#{label} '#{name}' is not defined in the catalog.")

      ids ->
        Failure.validation!(
          "#{label} '#{name}' is not in catalog '#{catalog_id}'. It is defined in: " <>
            Enum.map_join(ids, ", ", &"'#{&1}'") <> "."
        )
    end
  end

  @doc false
  @spec label(kind()) :: String.t()
  def label(:component), do: "Component"
  def label(:function), do: "Function"
end

defmodule A2UICore.Version do
  @moduledoc """
  A2UI protocol-version registry and catalog compatibility rules.

  Wire envelopes carry a string `version` field (`"v0.9"`, `"v0.9.1"`,
  `"v1.0"`). This module holds the supported set and the exact
  catalog-compatibility rule from the reference implementation
  (`DEFAULT_CATALOG_COMPATIBILITY` + the "same major ≥ 1" SemVer rule
  + normalization for non-semver identifiers).

  ## Compatibility rule (verbatim from upstream)

  1. Normalize both sides via `A2UICore.SemVer.to_canonical/1`.
  2. Equal canonicals ⇒ compatible.
  3. The explicit map (below) extends compatibility per message version.
  4. If both sides are SemVer and the catalog's major is ≥ 1 and equals
     the message's major, they're compatible (minor/patch ignored).
  5. Otherwise — fallback: normalized raw string equality.
  """

  alias A2UICore.SemVer

  @moduledoc since: "0.1.0"

  @type protocol_version :: String.t()

  @doc """
  All protocol versions known to this library, including legacy ones.
  """
  @spec all() :: [protocol_version()]
  def all, do: ["v0.8", "v0.9", "v0.9.1", "v1.0"]

  @doc """
  The versions this build implements. v0.8 is intentionally excluded.
  """
  @spec supported() :: [protocol_version()]
  def supported, do: ["v0.9", "v0.9.1", "v1.0"]

  @doc """
  True if `version` (after SemVer parse) matches a known protocol version.
  The candidate may be written `0.9`, `v0.9`, `0.9.1`, `v0.9.1`, `v1.0`.
  """
  @spec protocol_version?(term()) :: boolean()
  def protocol_version?(version) do
    match?({:ok, _}, to_protocol_version(version))
  end

  @doc """
  Resolves the protocol version a version designator names.

  `v0.9`, `v0.9.1` and `v1.0` (and any SemVer-equal variant such as
  `1.0.0-beta`) round-trip to the same protocol version. Invalid strings
  produce `:error` (never raise).
  """
  @spec to_protocol_version(term()) :: {:ok, protocol_version()} | :error
  def to_protocol_version(version) do
    case SemVer.to_semver(version) do
      :error ->
        :error

      {:ok, parsed} ->
        case Enum.find(all(), &same_point_release?(&1, parsed)) do
          nil -> :error
          candidate -> {:ok, candidate}
        end
    end
  end

  @spec same_point_release?(protocol_version(), SemVer.t()) :: boolean()
  defp same_point_release?(candidate, parsed) do
    case SemVer.to_semver(candidate) do
      {:ok, member} ->
        member.major == parsed.major and member.minor == parsed.minor and
          member.patch == parsed.patch

      :error ->
        false
    end
  end

  @doc """
  The default catalog-compatibility map (normalized canonical keys).

  Message canonical version → the catalog canonical versions it accepts.
  """
  @spec default_catalog_compatibility() :: %{String.t() => MapSet.t(String.t())}
  def default_catalog_compatibility do
    %{
      "0.8" => MapSet.new(["0.8"]),
      "0.9" => MapSet.new(["0.9", "0.9.1"]),
      "0.9.1" => MapSet.new(["0.9.1", "0.9"]),
      "1.0" => MapSet.new(["1.0"])
    }
  end

  @doc """
  Whether `catalog_version` is compatible with `message_version`
  per the rule documented in the moduledoc.

  ## Examples

      iex> A2UICore.Version.catalog_compatible?("v1.0", "v1.0")
      true
      iex> A2UICore.Version.catalog_compatible?("v0.9", "v0.9.1")
      true
      iex> A2UICore.Version.catalog_compatible?("v0.9.1", "v0.9")
      true
      iex> A2UICore.Version.catalog_compatible?("v1.0", "v0.9")
      false
      iex> A2UICore.Version.catalog_compatible?("unknown", "v1.0")
      false
  """
  @spec catalog_compatible?(term(), term()) :: boolean()
  def catalog_compatible?(catalog_version, message_version),
    do: catalog_compatible?(catalog_version, message_version, default_catalog_compatibility())

  @spec catalog_compatible?(term(), term(), map()) :: boolean()
  def catalog_compatible?(_, nil, _), do: false
  def catalog_compatible?(nil, _, _), do: false

  def catalog_compatible?(catalog_version, message_version, compatibility_map) do
    catalog_canonical = SemVer.to_canonical(catalog_version)
    message_canonical = SemVer.to_canonical(message_version)

    cond do
      is_nil(catalog_canonical) or is_nil(message_canonical) ->
        non_semver_compatible?(catalog_version, message_version)

      catalog_canonical == message_canonical ->
        true

      true ->
        covered_by_map?(catalog_canonical, message_canonical, compatibility_map) or
          same_gte_major?(catalog_version, message_version)
    end
  end

  @spec covered_by_map?(String.t(), String.t(), map()) :: boolean()
  defp covered_by_map?(catalog_canonical, message_canonical, compatibility_map) do
    case Map.get(compatibility_map, message_canonical) do
      nil -> false
      set when is_struct(set, MapSet) -> MapSet.member?(set, catalog_canonical)
      set when is_list(set) -> catalog_canonical in set
      other -> catalog_canonical == other
    end
  end

  @spec same_gte_major?(term(), term()) :: boolean()
  defp same_gte_major?(catalog_version, message_version) do
    with {:ok, catalog_semver} <- SemVer.to_semver(catalog_version),
         {:ok, message_semver} <- SemVer.to_semver(message_version) do
      catalog_semver.major >= 1 and catalog_semver.major == message_semver.major
    else
      _ -> false
    end
  end

  @spec non_semver_compatible?(term(), term()) :: boolean()
  defp non_semver_compatible?(catalog_version, message_version) do
    if is_binary(catalog_version) and is_binary(message_version) do
      catalog_normalized = SemVer.normalize(catalog_version)
      catalog_normalized != "" and catalog_normalized == SemVer.normalize(message_version)
    else
      false
    end
  end
end

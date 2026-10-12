defmodule A2UIConformance.Case do
  @moduledoc false

  # A single conformance case, bound to the suite file it came from.
  #
  # `scope` is the suite family the case belongs to — the same action
  # name means different things in different families (`resolve_path`
  # is a data-context resolver in `core/` but a file resolver in
  # `extensions/adk`), so dispatch keys on `{scope, action}`:
  #
  #   "core"                     core/*.yaml
  #   "agent"                    agent/*.yaml (blueprint shared suites)
  #   "agent/<format>"           agent/direct_json, agent/express, ...
  #   "extensions/<name>"        extensions/a2a, extensions/adk
  #
  # `protocol_version` follows the reference harness's
  # `resolve_protocol_version` (test_conformance.py L132-159), normalized
  # to the `v`-prefixed form (`"1.0"` -> `"v1.0"`).

  alias A2UICore.Version

  @enforce_keys [:name, :suite, :raw]
  defstruct [:name, :suite, :scope, :raw, :action, :protocol_version]

  @type t :: %__MODULE__{
          name: String.t(),
          suite: String.t(),
          scope: String.t(),
          action: String.t() | nil,
          protocol_version: String.t() | nil,
          raw: map()
        }

  @doc false
  @spec new(String.t(), String.t(), map()) :: t()
  def new(suite, name, raw) when is_map(raw) do
    %__MODULE__{
      name: name,
      suite: suite,
      scope: scope(suite),
      raw: raw,
      action: raw["action"],
      protocol_version: normalize_version(resolve_protocol_version(raw))
    }
  end

  @doc false
  @spec scope(String.t()) :: String.t()
  def scope(suite) do
    case Path.split(suite) do
      [family, _file] -> family
      [family, sub | _rest] -> family <> "/" <> sub
    end
  end

  @doc """
  Port of the reference `resolve_protocol_version`: the case's own
  `protocolVersion`, then `catalog.protocolVersion`, then
  `catalogSchema.protocolVersion`, then the first entry of `catalogs`
  that names one, then a heuristic on the catalog id, else `"v0.9"`.
  """
  @spec resolve_protocol_version(map()) :: String.t()
  def resolve_protocol_version(raw) do
    catalog = map_or_empty(raw["catalog"])
    catalog_schema = map_or_empty(raw["catalogSchema"])

    present(raw["protocolVersion"]) ||
      present(catalog["protocolVersion"]) ||
      present(catalog_schema["protocolVersion"]) ||
      first_catalogs_version(raw["catalogs"]) ||
      version_from_catalog_id(
        raw["catalogId"] || catalog["catalogId"] || catalog_schema["catalogId"]
      )
  end

  defp first_catalogs_version(catalogs) when is_list(catalogs) do
    Enum.find_value(catalogs, fn
      %{"protocolVersion" => version} -> present(version)
      _other -> nil
    end)
  end

  defp first_catalogs_version(_other), do: nil

  defp version_from_catalog_id(id) do
    id = to_string(id || "")

    cond do
      String.contains?(id, ["v08", "v0_8"]) -> "v0.8"
      String.contains?(id, ["v09", "v0_9"]) -> "v0.9"
      String.contains?(id, ["v10", "v1_0", "v1.0"]) -> "v1.0"
      true -> "v0.9"
    end
  end

  defp present(value) when value in [nil, "", false], do: nil
  defp present(value), do: to_string(value)

  defp map_or_empty(value) when is_map(value), do: value
  defp map_or_empty(_value), do: %{}

  # Bare `0.9`/`1.0` (accepted by the reference) map to the v-prefixed
  # protocol version; anything unparseable is kept for the skip policy
  # to report.
  defp normalize_version(version) do
    case Version.to_protocol_version(version) do
      {:ok, protocol_version} -> protocol_version
      :error -> version
    end
  end
end

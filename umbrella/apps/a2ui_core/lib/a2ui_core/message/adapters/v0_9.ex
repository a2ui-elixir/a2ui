# Named after the protocol version it adapts (`v0_9`, `v1_0`).
# credo:disable-for-next-line Credo.Check.Readability.ModuleNames
defmodule A2UICore.Message.Adapters.V0_9 do
  @moduledoc false

  # Protocol v0.9 / v0.9.1 adapter. Validates against the v0.9.1
  # envelope documents (their `version` enum accepts both patch
  # releases) and builds canonical operations from the v0.9 action set.

  alias A2UICore.Message.Adapter
  alias A2UICore.Message.Operation
  alias A2UICore.SemVer

  @behaviour Adapter

  @actions ["createSurface", "updateComponents", "updateDataModel", "deleteSurface"]

  @impl Adapter
  def version, do: "v0.9"

  @impl Adapter
  def document_version, do: "v0.9.1"

  @impl Adapter
  def compatible_catalog_versions, do: MapSet.new(["0.9", "0.9.1"])

  @impl Adapter
  def valid_actions, do: @actions

  @impl Adapter
  def prepare_message(message) do
    message
    |> prepare_bare_version()
    |> normalize_patch_release()
  end

  # Base rule: only a *bare* canonical version ("0.9"/"0.9.1") gains
  # its `v` prefix (reference `prepare_payload_for_validation`).
  defp prepare_bare_version(%{"version" => <<first, _::binary>> = raw} = message)
       when first != ?v do
    case SemVer.to_canonical(raw) do
      canonical when canonical in ["0.9", "0.9.1"] ->
        %{message | "version" => "v" <> canonical}

      _other ->
        message
    end
  end

  defp prepare_bare_version(message), do: message

  # v0.9 subclass: "v0.9.1" is rewritten to "v0.9" before schema
  # validation (the vendored v0.9.1 schema accepts both spellings, the
  # rewrite mirrors the reference adapter exactly).
  defp normalize_patch_release(%{"version" => "v0.9.1"} = message),
    do: %{message | "version" => "v0.9"}

  defp normalize_patch_release(message), do: message

  @impl Adapter
  def extract_operations("createSurface", %{"createSurface" => cs} = message) do
    [
      %Operation.CreateSurface{
        surface_id: surface_id(cs),
        catalog_id: cs["catalogId"],
        theme: cs["theme"],
        send_data_model: truthy?(cs["sendDataModel"], false),
        components: cs["components"],
        data_model: cs["dataModel"],
        version: message["version"] || version()
      }
    ]
  end

  def extract_operations("updateComponents", %{"updateComponents" => uc}) do
    [
      %Operation.UpdateComponents{
        surface_id: surface_id(uc),
        components: Map.get(uc, "components", [])
      }
    ]
  end

  def extract_operations("updateDataModel", %{"updateDataModel" => ud}) do
    [
      %Operation.UpdateDataModel{
        surface_id: surface_id(ud),
        path: Map.get(ud, "path", "/"),
        value: ud["value"]
      }
    ]
  end

  def extract_operations("deleteSurface", %{"deleteSurface" => ds}) do
    [%Operation.DeleteSurface{surface_id: surface_id(ds)}]
  end

  def extract_operations(action, _message),
    do: raise(ArgumentError, "unexpected action #{inspect(action)} in V0_9 adapter")

  defp surface_id(action), do: Map.get(action, "surfaceId", "")

  defp truthy?(value, _default) when is_boolean(value), do: value
  defp truthy?(_other, default), do: default
end

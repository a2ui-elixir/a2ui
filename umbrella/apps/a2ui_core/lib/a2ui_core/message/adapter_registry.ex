defmodule A2UICore.Message.AdapterRegistry do
  @moduledoc """
  Resolves version adapters from version strings and raw payloads — a
  faithful port of the reference `VersionAdapterFactory`, including
  its error detail paths (`messages.0.version`, …).

  v0.8 is not supported by this implementation: a version of `v0.8` (or
  a payload using the legacy v0.8 action keys) resolves to an
  `:unsupported_version` error rather than an adapter.
  """

  alias A2UICore.Error
  alias A2UICore.Error.Detail
  alias A2UICore.Message.Adapters.{V0_9, V1_0}
  alias A2UICore.SemVer

  @moduledoc since: "0.1.0"

  @adapters %{"v0.9" => V0_9, "v0.9.1" => V0_9, "v1.0" => V1_0}

  @v0_8_action_keys ["beginRendering", "surfaceUpdate", "dataModelUpdate", "deleteSurface"]

  @doc """
  All action keys known across the protocol family — including the
  legacy v0.8 keys, which this implementation *lists* (so the
  "action not supported in this version" error stays faithful to the
  reference) but does not implement.
  """
  @spec all_known_actions() :: MapSet.t(String.t())
  def all_known_actions do
    registered = Enum.flat_map(Map.values(@adapters), & &1.valid_actions())
    MapSet.new(registered ++ @v0_8_action_keys)
  end

  @doc """
  Resolves the adapter module for a version designator.

  Accepts `v0.9`, `0.9`, `v0.9.1`, `v1.0`, `1.0`, `v1_0` … via
  canonicalization. Returns `{:ok, module}` or `{:error, error}`
  (category `:validation`) for unsupported versions such as `v0.8` or
  `v99.0`.
  """
  @spec get_adapter(String.t()) :: {:ok, module()} | {:error, Error.t()}
  def get_adapter(version) when is_binary(version) do
    case canonical_protocol_version(version) do
      nil -> {:error, unsupported_version_error(version)}
      canonical -> adapter_for_canonical(canonical, version)
    end
  end

  defp adapter_for_canonical("0.9", _original), do: {:ok, @adapters["v0.9"]}
  defp adapter_for_canonical("0.9.1", _original), do: {:ok, @adapters["v0.9.1"]}
  defp adapter_for_canonical("1.0", _original), do: {:ok, @adapters["v1.0"]}
  defp adapter_for_canonical(_other, original), do: {:error, unsupported_version_error(original)}

  defp canonical_protocol_version(version) do
    case SemVer.to_canonical(version) do
      canonical when canonical in ["0.9", "0.9.1", "1.0"] -> canonical
      _other -> nil
    end
  end

  defp unsupported_version_error(version) do
    supported =
      @adapters |> Map.keys() |> Enum.sort() |> Enum.join(", ")

    Error.new(
      :validation,
      "unsupported_version",
      "[VersionAdapterFactory] Unsupported protocol version '#{version}'." <>
        " Supported versions: #{supported}."
    )
  end

  @doc """
  Resolves the adapter directly from a raw payload (a message map, a
  list of messages, or a `{"messages": [...]}` wrapper).

  Sniffing order (faithful to the reference):

  1. non-list/map payloads are rejected (`invalid_payload_type`),
  2. an empty list is rejected (`empty_payload`),
  3. `{"messages": [...]}` wrappers recurse into the list,
  4. lists resolve via their first item,
  5. the item must be a map (`invalid_payload_type`),
  6. a string `version` resolves the adapter (`type_mismatch` when
     present but not a string); a missing version falls back to the
     legacy v0.8 action keys — which this implementation reports as
     unsupported — and otherwise fails with `missing_field`.

  All failures carry a detail at path `messages.{index}.version`.
  """
  @spec resolve_from_payload(term()) :: {:ok, module()} | {:error, Error.t()}
  def resolve_from_payload(payload) do
    case payload do
      map when is_map(map) ->
        case map do
          %{"messages" => messages} when is_list(messages) -> resolve_from_payload(messages)
          _single -> resolve_from_item(map, 0)
        end

      list when is_list(list) ->
        case list do
          [] -> {:error, empty_payload_error()}
          [first | _] -> resolve_from_item(first, 0)
        end

      _other ->
        {:error, invalid_payload_type_error(type_name(payload))}
    end
  end

  defp resolve_from_item(item, index) do
    case item do
      map when is_map(map) ->
        resolve_version_key(map, index)

      _other ->
        {:error,
         Error.new(
           :validation,
           "INVALID_VERSION",
           "[VersionAdapterFactory] Message payload is missing a valid 'version'" <>
             " string: message item at index #{index} is not an object.",
           details: [
             Detail.new(
               "invalid_payload_type",
               "Message item is not an object",
               "messages.#{index}.version"
             )
           ]
         )}
    end
  end

  defp resolve_version_key(message, index) do
    case message do
      %{"version" => version} when is_binary(version) ->
        get_adapter(version)

      %{"version" => version} when not is_binary(version) ->
        {:error,
         Error.new(
           :validation,
           "INVALID_VERSION",
           "[VersionAdapterFactory] Message payload is missing a valid 'version'" <>
             " string: 'version' property must be a string, got #{type_name(version)}.",
           details: [
             Detail.new(
               "type_mismatch",
               "Expected string for 'version', got #{type_name(version)}",
               "messages.#{index}.version"
             )
           ]
         )}

      _missing_version ->
        if Enum.any?(@v0_8_action_keys, &Map.has_key?(message, &1)) do
          # Legacy v0.8 payloads would route to the v0.8 adapter in the
          # reference; we surface that as an explicit unsupported error.
          {:error, unsupported_version_error("v0.8")}
        else
          {:error,
           Error.new(
             :validation,
             "INVALID_VERSION",
             "[VersionAdapterFactory] Message payload is missing a valid 'version'" <>
               " string: no version header or legacy v0.8 action found.",
             details: [
               Detail.new(
                 "missing_field",
                 "Missing required version field",
                 "messages.#{index}.version"
               )
             ]
           )}
        end
    end
  end

  defp empty_payload_error do
    Error.new(
      :validation,
      "INVALID_VERSION",
      "[VersionAdapterFactory] Message payload is missing a valid 'version'" <>
        " string: message list is empty.",
      details: [Detail.new("empty_payload", "Message list is empty", "messages.0.version")]
    )
  end

  defp invalid_payload_type_error(type) do
    Error.new(
      :validation,
      "INVALID_VERSION",
      "[VersionAdapterFactory] Message payload is missing a valid 'version'" <>
        " string: expected object or list, got #{type}.",
      details: [
        Detail.new(
          "invalid_payload_type",
          "Expected object or list, got #{type}",
          "messages.0.version"
        )
      ]
    )
  end

  defp type_name(nil), do: "null"
  defp type_name(value) when is_integer(value), do: "integer"
  defp type_name(value) when is_float(value), do: "float"
  defp type_name(value) when is_boolean(value), do: "boolean"
  defp type_name(value) when is_binary(value), do: "string"
  defp type_name(value) when is_list(value), do: "list"
  defp type_name(value) when is_map(value), do: "map"
  defp type_name(_other), do: "term"
end

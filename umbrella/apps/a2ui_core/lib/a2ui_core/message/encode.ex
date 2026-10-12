defmodule A2UICore.Message.Encode do
  @moduledoc false

  # Canonical operations → wire-format message maps.
  #
  # Mirrors the reference `to_message_dicts` contract:
  #
  #   * only meaningful fields are emitted (nil optionals are omitted),
  #   * `version` always leads the message (v0.9+ wire requirement),
  #   * v1.0 `updateDataModel` always carries an explicit `value`
  #     (`null` is the wire form of delete; omitting it is a schema
  #     error in v1.0), while v0.9 omits a nil value,
  #   * v1.0 create keeps inline `components`/`dataModel` when the
  #     operation carries them (agent-side authors may construct the
  #     single-message instantiation directly).

  alias A2UICore.Message.Operation

  alias A2UICore.Message.Operation.{
    AgentFunctionResponse,
    CallRendererFunction,
    CreateSurface,
    DeleteSurface,
    UpdateComponents,
    UpdateDataModel
  }

  alias A2UICore.SemVer

  @doc """
  Encodes one operation into a wire-format message map.

  The protocol version is derived from the operation (its `version`
  field for create/RPC ops, falling back to the op shape); `:version`
  overrides it explicitly (e.g. `"v0.9"` vs `"v0.9.1"`).
  """
  @spec to_map(Operation.t(), keyword()) :: map()
  def to_map(op, overrides \\ [])

  def to_map(%CreateSurface{} = op, overrides) do
    version = Keyword.get(overrides, :version) || op.version || "v0.9"

    payload =
      %{"surfaceId" => op.surface_id}
      |> put_if("catalogId", op.catalog_id)
      |> put_theme_if_v0_9(op, version)
      |> put_if("sendDataModel", (op.send_data_model == true && true) || nil)
      |> put_if("components", op.components)
      |> put_if("dataModel", op.data_model)

    %{"version" => version, "createSurface" => payload}
  end

  def to_map(%UpdateComponents{} = op, overrides) do
    version = Keyword.get(overrides, :version) || "v0.9"

    %{
      "version" => version,
      "updateComponents" => %{"surfaceId" => op.surface_id, "components" => op.components}
    }
  end

  def to_map(%UpdateDataModel{} = op, overrides) do
    version = Keyword.get(overrides, :version) || "v0.9"

    payload =
      case SemVer.to_canonical(version) do
        "1.0" ->
          # v1.0: `value` is required on the wire; null is the delete form.
          base = %{"surfaceId" => op.surface_id, "value" => op.value}
          put_if(base, "path", op.path)

        _v0_9 ->
          # v0.9: a nil value is omitted entirely (delete).
          base = %{"surfaceId" => op.surface_id}
          base = put_if(base, "path", op.path)
          put_if(base, "value", op.value)
      end

    %{"version" => version, "updateDataModel" => payload}
  end

  def to_map(%DeleteSurface{} = op, overrides) do
    version = Keyword.get(overrides, :version) || "v0.9"
    %{"version" => version, "deleteSurface" => %{"surfaceId" => op.surface_id}}
  end

  def to_map(%CallRendererFunction{} = op, overrides) do
    version = Keyword.get(overrides, :version) || op.version || "v1.0"

    call_function =
      %{"@call" => op.call}
      |> put_if("catalogId", op.catalog_id)
      |> put_if("args", empty_map_to_nil(op.args))

    %{
      "version" => version,
      "callRendererFunction" => %{
        "functionCallId" => op.function_call_id,
        "callFunction" => call_function
      }
    }
  end

  def to_map(%AgentFunctionResponse{} = op, overrides) do
    version = Keyword.get(overrides, :version) || op.version || "v1.0"

    payload =
      case op.error do
        nil ->
          %{"functionCallId" => op.function_call_id, "value" => op.value}

        error ->
          %{
            "functionCallId" => op.function_call_id,
            "error" => %{"code" => error["code"], "message" => error["message"]}
          }
      end

    %{"version" => version, "agentFunctionResponse" => payload}
  end

  @doc """
  Encodes many operations to a JSON-encodable list of wire maps.
  """
  @spec to_maps([Operation.t()], keyword()) :: [map()]
  def to_maps(ops, overrides \\ []),
    do: Enum.map(ops, &to_map(&1, overrides))

  defp put_if(map, _key, nil), do: map
  defp put_if(map, key, value), do: Map.put(map, key, value)

  defp put_theme_if_v0_9(map, op, version) do
    case SemVer.to_canonical(version) do
      "1.0" -> map
      _v0_9 -> put_if(map, "theme", op.theme)
    end
  end

  defp empty_map_to_nil(args) when args == %{}, do: nil
  defp empty_map_to_nil(args), do: args
end

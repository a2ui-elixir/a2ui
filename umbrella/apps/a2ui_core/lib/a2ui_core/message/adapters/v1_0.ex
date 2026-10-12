defmodule A2UICore.Message.Adapters.V1_0 do
  @moduledoc false

  # Protocol v1.0 adapter. Adds `callRendererFunction` and
  # `agentFunctionResponse`, and expands a `createSurface` with inline
  # `components`/`dataModel` into separate canonical operations after the
  # create — exactly like the reference implementation.

  alias A2UICore.Message.Adapter
  alias A2UICore.Message.Operation
  alias A2UICore.SemVer

  @behaviour Adapter

  @actions [
    "createSurface",
    "updateComponents",
    "updateDataModel",
    "deleteSurface",
    "callRendererFunction",
    "agentFunctionResponse"
  ]

  @impl Adapter
  def version, do: "v1.0"

  @impl Adapter
  def document_version, do: "v1.0"

  @impl Adapter
  def compatible_catalog_versions, do: MapSet.new(["1.0"])

  @impl Adapter
  def valid_actions, do: @actions

  @impl Adapter
  # Mirrors the reference `prepare_payload_for_validation`: only a
  # *bare* canonical version ("1.0") gains its `v` prefix. "v1.0.0"
  # and friends pass the compatibility check (they canonicalize to
  # "1.0") but then fail the schema's `const "v1.0"` — same as the
  # reference's pydantic literal.
  def prepare_message(%{"version" => <<first, _::binary>> = raw} = message)
      when first != ?v do
    case SemVer.to_canonical(raw) do
      "1.0" -> %{message | "version" => "v1.0"}
      _other -> message
    end
  end

  def prepare_message(message), do: message

  @impl Adapter
  def extract_operations("createSurface", %{"createSurface" => cs} = message) do
    [
      %Operation.CreateSurface{
        surface_id: surface_id(cs),
        catalog_id: cs["catalogId"],
        send_data_model: truthy?(cs["sendDataModel"], false),
        version: message["version"] || version()
      }
      | inline_operations(cs, surface_id(cs))
    ]
  end

  def extract_operations("updateComponents", %{"updateComponents" => uc}) do
    [
      %Operation.UpdateComponents{
        surface_id: surface_id(uc),
        components: uc["components"] || []
      }
    ]
  end

  def extract_operations("updateDataModel", %{"updateDataModel" => udm}) do
    [
      %Operation.UpdateDataModel{
        surface_id: surface_id(udm),
        path: udm["path"] || "/",
        value: udm["value"]
      }
    ]
  end

  def extract_operations("deleteSurface", %{"deleteSurface" => ds}) do
    [%Operation.DeleteSurface{surface_id: surface_id(ds)}]
  end

  def extract_operations("callRendererFunction", %{"callRendererFunction" => crf}) do
    call_function = crf["callFunction"] || %{}

    [
      %Operation.CallRendererFunction{
        function_call_id: crf["functionCallId"],
        call: call_function["@call"],
        catalog_id: call_function["catalogId"],
        args: call_function["args"] || %{},
        version: version()
      }
    ]
  end

  def extract_operations("agentFunctionResponse", %{"agentFunctionResponse" => resp}) do
    [
      %Operation.AgentFunctionResponse{
        function_call_id: resp["functionCallId"],
        value: resp["value"],
        error: resp["error"],
        version: version()
      }
    ]
  end

  def extract_operations(action, _message),
    do: raise(ArgumentError, "unexpected action #{inspect(action)} in V1_0 adapter")

  # v1.0 single-message instantiation: inline components/dataModel
  # become separate update operations after the create.
  defp inline_operations(cs, surface_id) do
    component_op =
      case cs["components"] do
        nil -> []
        components -> [%Operation.UpdateComponents{surface_id: surface_id, components: components}]
      end

    data_model_op =
      case cs["dataModel"] do
        nil -> []
        data_model -> [%Operation.UpdateDataModel{surface_id: surface_id, path: "/", value: data_model}]
      end

    component_op ++ data_model_op
  end

  defp surface_id(action), do: Map.get(action, "surfaceId", "")

  defp truthy?(value, _default) when is_boolean(value), do: value
  defp truthy?(_other, default), do: default
end
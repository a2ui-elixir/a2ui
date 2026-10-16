defmodule A2UICore.Message.Operation do
  @moduledoc """
  Version-neutral operations: what `A2UICore.Message.decode/2` returns
  and `A2UICore.Processor.apply_operations/3` applies.

  Adapters (`A2UICore.Message.Adapter`) normalize wire envelopes into
  these structs; every later stage (surface lifecycle, data model,
  RPC) works only against them. Field names mirror the wire (`surfaceId`
  → `surface_id`), and the version-specific edge cases are smoothed out
  at construction:

    * `v0.9.x` `updateDataModel` may omit `value` (delete) — `value` is
      `nil` either way; v1.0's explicit `null` and v0.9's omission are
      the same canonical op.
    * `v1.0` `createSurface` may inline `components` and `dataModel`;
      the v1.0 adapter expands those into separate
      `update_components`/`update_data_model` ops after the
      `create_surface` op, exactly like the reference implementation.
    * `v0.9.x` carries `theme` through to the surface; v1.0 drops it.
  """

  alias A2UICore.Message.Operation.{
    AgentFunctionResponse,
    CallRendererFunction,
    CreateSurface,
    DeleteSurface,
    UpdateComponents,
    UpdateDataModel
  }

  @moduledoc since: "0.1.0"

  @type t ::
          CreateSurface.t()
          | UpdateComponents.t()
          | UpdateDataModel.t()
          | DeleteSurface.t()
          | CallRendererFunction.t()
          | AgentFunctionResponse.t()

  @doc """
  The canonical action key of an operation (matching the wire's
  message-type keys).
  """
  @spec action(t()) :: String.t()
  def action(%CreateSurface{}), do: "createSurface"
  def action(%UpdateComponents{}), do: "updateComponents"
  def action(%UpdateDataModel{}), do: "updateDataModel"
  def action(%DeleteSurface{}), do: "deleteSurface"
  def action(%CallRendererFunction{}), do: "callRendererFunction"
  def action(%AgentFunctionResponse{}), do: "agentFunctionResponse"
end

defmodule A2UICore.Message.Operation.CreateSurface do
  @moduledoc """
  A `createSurface` message: a new surface, the catalog it uses
  (`catalog_id`) and whether the renderer sends its data model back
  (`send_data_model`). `theme` is kept for v0.9 messages only. A v1.0
  message may carry the surface's first `components` and `data_model`.
  """

  @moduledoc since: "0.1.0"

  @enforce_keys [:surface_id]
  defstruct [
    :surface_id,
    :catalog_id,
    :theme,
    :version,
    send_data_model: false,
    components: nil,
    data_model: nil,
    root: nil
  ]

  @type t :: %__MODULE__{
          surface_id: String.t(),
          catalog_id: String.t() | nil,
          theme: term() | nil,
          send_data_model: boolean(),
          components: [map()] | nil,
          data_model: term() | nil,
          root: String.t() | nil,
          version: String.t() | nil
        }
end

defmodule A2UICore.Message.Operation.UpdateComponents do
  @moduledoc """
  An `updateComponents` message: components to add to a surface or
  replace in it, as the wire maps.
  """

  @moduledoc since: "0.1.0"

  @enforce_keys [:surface_id, :components]
  defstruct [:surface_id, :components]

  @type t :: %__MODULE__{
          surface_id: String.t(),
          components: [map()]
        }
end

defmodule A2UICore.Message.Operation.UpdateDataModel do
  @moduledoc """
  An `updateDataModel` message: `value` written at `path` (the root by
  default) of a surface's data model. A `nil` value deletes.
  """

  @moduledoc since: "0.1.0"

  @enforce_keys [:surface_id]
  defstruct [:surface_id, :value, path: "/"]

  @type t :: %__MODULE__{
          surface_id: String.t(),
          path: String.t(),
          value: term()
        }
end

defmodule A2UICore.Message.Operation.DeleteSurface do
  @moduledoc """
  A `deleteSurface` message.
  """

  @moduledoc since: "0.1.0"

  @enforce_keys [:surface_id]
  defstruct [:surface_id]

  @type t :: %__MODULE__{surface_id: String.t()}
end

defmodule A2UICore.Message.Operation.CallRendererFunction do
  @moduledoc """
  A `callRendererFunction` message (v1.0): the agent asks the renderer
  to run function `call` with `args`, from the catalog `catalog_id`,
  in the context of surface `surface_id` (or of no surface when `nil`).
  The answer must carry `function_call_id`.
  """

  @moduledoc since: "0.1.0"

  @enforce_keys [:function_call_id, :call]
  defstruct [:function_call_id, :call, :catalog_id, :surface_id, version: "v1.0", args: %{}]

  @type t :: %__MODULE__{
          function_call_id: String.t(),
          call: String.t(),
          catalog_id: String.t() | nil,
          surface_id: String.t() | nil,
          args: map(),
          version: String.t()
        }
end

defmodule A2UICore.Message.Operation.AgentFunctionResponse do
  @moduledoc """
  An `agentFunctionResponse` message (v1.0): the agent's answer to the
  renderer's call `function_call_id`, either a `value` or an `error`
  map with `"code"` and `"message"`.
  """

  @moduledoc since: "0.1.0"

  @enforce_keys [:function_call_id]
  defstruct [:function_call_id, :value, :error, version: "v1.0"]

  @type t :: %__MODULE__{
          function_call_id: String.t(),
          value: term() | nil,
          error: %{optional(String.t()) => term()} | nil,
          version: String.t()
        }
end

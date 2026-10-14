defmodule A2UIAgent.A2A.Request do
  @moduledoc """
  One A2A `message/send` or `message/stream` request, as
  `A2UIAgent.A2A.Server` hands it to the agent.

    * `:id` — the JSON-RPC request id.
    * `:method` — `"message/send"` or `"message/stream"`.
    * `:message` — the A2A message, as the client sent it.
    * `:task_id`, `:context_id` — the message's, or new ones.
    * `:text` — the message's text parts, joined.
    * `:events` — the A2UI messages its A2UI data parts carry, such as
      `action` messages from the renderer.
    * `:capabilities` — the renderer capabilities from the message
      metadata (`a2uiRendererCapabilities`, `a2uiClientCapabilities`), or
      `nil`.
    * `:data_model` — the renderer data model from the message metadata
      (`a2uiRendererDataModel`, `a2uiClientDataModel`), or `nil`.
    * `:extensions` — the A2UI extension URIs the client requested.
    * `:activated` — `{uri, version}` of the A2UI extension activated for
      this request, or `nil`.
    * `:processor` — the `A2UIAgent.RequestProcessor` negotiated for the
      renderer, or `nil` when the agent answers in text only.
    * `:version` — the protocol version of the processor's catalogs.
  """

  alias A2UIAgent.RequestProcessor

  @moduledoc since: "0.1.0"

  @enforce_keys [:id, :method, :message, :task_id, :context_id]
  defstruct [
    :id,
    :method,
    :message,
    :task_id,
    :context_id,
    :capabilities,
    :data_model,
    :activated,
    :processor,
    :version,
    text: "",
    events: [],
    extensions: []
  ]

  @type t :: %__MODULE__{
          id: String.t() | integer() | nil,
          method: String.t(),
          message: map(),
          task_id: String.t(),
          context_id: String.t(),
          text: String.t(),
          events: [map()],
          capabilities: map() | nil,
          data_model: map() | nil,
          extensions: [String.t()],
          activated: {String.t(), String.t()} | nil,
          processor: RequestProcessor.t() | nil,
          version: String.t() | nil
        }
end

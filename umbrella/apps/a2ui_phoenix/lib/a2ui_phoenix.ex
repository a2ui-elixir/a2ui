defmodule A2UIPhoenix do
  @moduledoc """
  Phoenix/LiveView renderer adapter for [`A2UICore`](../a2ui_core/readme.html).

  Renders A2UI surfaces as LiveView function components, serves agent
  transports (LiveView channel, SSE, A2A), and executes surfaced `Processor`
  effects (actions, RPC responses). Depends on `a2ui_core`; adds no global
  processes — state lives in the host's LiveView assigns.
  """
end

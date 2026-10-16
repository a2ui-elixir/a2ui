defmodule A2UIPhoenix do
  @moduledoc """
  Phoenix/LiveView renderer for `A2UICore`.

    * `A2UIPhoenix.Session` — the renderer state of a conversation: the
      surfaces an agent built and their resolved component trees; plain
      data, effects returned.
    * `A2UIPhoenix.Live` — hosts a session in a LiveView: applies agent
      messages, the surfaces' writes and actions, and delivers outbound
      messages through a callback.
    * `A2UIPhoenix.Surface` — the LiveComponent that renders one surface.
    * `A2UIPhoenix.Components.Basic` — the basic catalog's components;
      `A2UIPhoenix.Components` and `A2UIPhoenix.Context` for writing
      components of another catalog.
    * `A2UIPhoenix.Plug.SSE` — streams agent messages to renderers
      outside LiveView as server-sent events.

  No global processes: state lives in the host's LiveView assigns.
  `priv/static/a2ui_phoenix.js` opens the URLs `openUrl` actions ask for,
  and `priv/static/a2ui_phoenix.css` draws the components, in light and
  dark, themed by `--a2ui-*` custom properties (see the guide).
  """
end

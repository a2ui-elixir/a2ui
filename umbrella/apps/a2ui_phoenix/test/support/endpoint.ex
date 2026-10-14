defmodule A2UIPhoenix.Test.Endpoint do
  @moduledoc false
  # The endpoint LiveViewTest drives the host LiveView through; it is
  # configured and started by test_helper.exs.
  use Phoenix.Endpoint, otp_app: :a2ui_phoenix

  socket("/live", Phoenix.LiveView.Socket)
end

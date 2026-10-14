Application.put_env(:a2ui_phoenix, A2UIPhoenix.Test.Endpoint,
  url: [host: "localhost"],
  secret_key_base: String.duplicate("a2ui-phoenix-test", 4),
  live_view: [signing_salt: "a2ui-phoenix-test"],
  check_origin: false,
  server: false
)

{:ok, _pid} = A2UIPhoenix.Test.Endpoint.start_link()

ExUnit.start()

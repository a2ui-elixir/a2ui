defmodule RestaurantAgent.Test.A2A do
  @moduledoc false
  # Builds A2A requests the way a client does, and reads the answers.

  alias A2UIAgent.A2A

  @basic "https://a2ui.org/specification/v1_0/catalogs/basic/catalog.json"
  @restaurant "https://example.com/a2ui/catalogs/restaurant/v1/catalog.json"
  @basic09 "https://a2ui.org/specification/v0_9/catalogs/basic/catalog.json"

  def basic, do: @basic
  def restaurant, do: @restaurant

  def capabilities(:v1),
    do: %{
      "a2uiRendererCapabilities" => %{"v1.0" => %{"supportedCatalogIds" => [@basic, @restaurant]}}
    }

  def capabilities(:v09),
    do: %{"a2uiClientCapabilities" => %{"v0.9" => %{"supportedCatalogIds" => [@basic09]}}}

  def capabilities(:none), do: %{}

  def body(parts, version \\ :v1, options \\ []) do
    message = %{
      "kind" => "message",
      "messageId" => Keyword.get(options, :message_id, "m1"),
      "role" => "user",
      "parts" => List.wrap(parts),
      "metadata" => capabilities(version)
    }

    %{
      "jsonrpc" => "2.0",
      "id" => 1,
      "method" => Keyword.get(options, :method, "message/send"),
      "params" => %{"message" => message}
    }
  end

  def text(text), do: A2A.text_part(text)
  def data(message), do: A2A.a2ui_part(message, message["version"] || "v1.0")

  def action(name, surface_id, context \\ %{}) do
    %{
      "version" => "v1.0",
      "action" => %{
        "name" => name,
        "surfaceId" => surface_id,
        "sourceComponentId" => "button",
        "timestamp" => "2026-10-16T12:00:00Z",
        "context" => context
      }
    }
  end

  # The texts and A2UI messages of a finished task.
  def answer(response) do
    parts = get_in(response, ["result", "status", "message", "parts"]) || []
    {for(%{"kind" => "text", "text" => text} <- parts, do: text), A2A.a2ui_messages(parts)}
  end

  def send_message(agent, body) do
    {:reply, response, _extensions} = A2A.Server.handle(body, agent, agent.options())
    answer(response)
  end

  def keys(messages), do: Enum.map(messages, &(&1 |> Map.delete("version") |> Map.keys() |> hd()))
end

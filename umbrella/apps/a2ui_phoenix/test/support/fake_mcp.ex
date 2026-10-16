defmodule A2UIPhoenix.Test.FakeMCP do
  @moduledoc false
  # An MCP server for tests: `results` by tool name (default: an empty
  # result) and `resources` by URI; calls are reported to `test`.

  @behaviour A2UICore.MCP.Client

  @impl true
  def call_tool(state, name, arguments) do
    send(state.test, {:call_tool, name, arguments})

    case Map.get(state[:results] || %{}, name, {:ok, %{"content" => []}}) do
      :raise -> raise ArgumentError, "server crashed"
      reply -> reply
    end
  end

  @impl true
  def read_resource(state, uri),
    do: Map.get(state[:resources] || %{}, uri, {:error, "no resource #{uri}"})
end

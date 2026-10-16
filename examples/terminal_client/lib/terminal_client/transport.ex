defmodule TerminalClient.Transport do
  @moduledoc """
  A way of talking to the agent. Each transport carries the user's text
  and the renderer's messages to the agent, and brings back the agent's
  text and A2UI messages, in order.

  Not every transport carries every renderer message: MCP and AG-UI
  carry actions and errors, server-sent events carry nothing back.
  `supports?/1` says which; the chat leaves the others out and says so.
  """

  @typedoc "What goes to the agent: the user's text, or a renderer message."
  @type input :: {:text, String.t()} | {:message, map()}

  @typedoc "What comes back: the agent's text, or A2UI messages to apply."
  @type output :: {:text, String.t()} | {:a2ui, [map()]}

  @doc "Connects to the agent at `url`. Options are the transport's."
  @callback connect(url :: String.t(), options :: keyword()) :: {:ok, term()} | {:error, term()}

  @doc """
  Sends `inputs` with the renderer's `metadata` (capabilities, data
  model). `on_output` is called with each output as it arrives, for
  transports that stream.
  """
  @callback request(
              state :: term(),
              [input()],
              metadata :: map(),
              on_output :: (output() -> any())
            ) ::
              {:ok, term(), [output()]} | {:error, term()}

  @doc "Whether the transport carries this renderer message to the agent."
  @callback supports?(message :: map()) :: boolean()

  @doc "The transports by name."
  @spec all() :: %{String.t() => module()}
  def all do
    %{
      "a2a" => TerminalClient.Transports.A2A,
      "express" => TerminalClient.Transports.A2A,
      "mcp" => TerminalClient.Transports.MCP,
      "agui" => TerminalClient.Transports.AGUI,
      "sse" => TerminalClient.Transports.SSE,
      "ws" => TerminalClient.Transports.WebSocket
    }
  end
end

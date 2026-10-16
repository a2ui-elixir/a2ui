defmodule Mix.Tasks.Chat do
  @shortdoc "Talks to the restaurant agent from the terminal"
  @moduledoc """
  Talks to an A2UI agent, drawing its surfaces as text.

      mix chat "Find Italian restaurants" "click:Book a table" \\
        "type:Your name=Ada" "type:Email=ada@example.com" "click:Confirm booking"

  Each argument is a step: text to say, `click:LABEL` (`click:LABEL#1`
  for the second button with that label) or `type:LABEL=VALUE`. Without
  steps the task reads them from standard input, one per line, until an
  empty line.

  Options:

    * `--transport` — `a2a` (default), `express` (A2A, the model writes
      Express), `mcp`, `agui`, `sse` or `ws`;
    * `--url` — the agent's base URL (default `http://127.0.0.1:4001`);
    * `--version` — `v1.0` (default) or `v0.9`;
    * `--stream` — use A2A's `message/stream`.
  """

  use Mix.Task

  alias TerminalClient.Chat

  @switches [transport: :string, url: :string, version: :string, stream: :boolean]

  @impl true
  def run(args) do
    {options, steps} = OptionParser.parse!(args, strict: @switches)
    Mix.Task.run("app.start")

    case Chat.connect(options) do
      {:ok, chat} ->
        steps =
          if steps == [],
            do: Stream.map(lines(), &Chat.parse/1),
            else: Enum.map(steps, &Chat.parse/1)

        case Chat.run(chat, steps) do
          {:ok, _chat} -> :ok
          {:error, reason, _chat} -> Mix.raise(reason)
        end

      {:error, reason} ->
        Mix.raise("Cannot reach the agent: #{inspect(reason)}")
    end
  end

  defp lines do
    Stream.repeatedly(fn -> IO.gets("") end)
    |> Stream.take_while(&(is_binary(&1) and String.trim(&1) != ""))
    |> Stream.map(&String.trim/1)
  end
end

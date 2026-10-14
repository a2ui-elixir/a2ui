defmodule A2UIAgent.A2A.Agent do
  @moduledoc """
  An agent that `A2UIAgent.A2A.Server` and `A2UIAgent.A2A.Plug` serve.

      defmodule MyAgent do
        @behaviour A2UIAgent.A2A.Agent

        alias A2UIAgent.A2A.Request

        @impl true
        def run(%Request{processor: nil, text: text}), do: {:ok, MyModel.reply(text)}

        def run(%Request{processor: processor, text: text}) do
          {:ok, prompt} = A2UIAgent.RequestProcessor.prompt(processor)
          {:ok, MyModel.stream(prompt, text)}
        end

        @impl true
        def options, do: [generator: MyAgent.Catalogs.generator()]

        @impl true
        def card do
          %{
            "name" => "My agent",
            "capabilities" => %{"extensions" => [A2UIAgent.A2A.agent_extension("1.0")]}
          }
        end
      end
  """

  alias A2UIAgent.A2A.{Request, Server}

  @moduledoc since: "0.1.0"

  @doc """
  Answers a request: the model's output (a string or an enumerable of
  chunks) and optionally the state the task ends in, or an error.
  """
  @callback run(Request.t()) :: Server.agent_result()

  @doc "The `A2UIAgent.A2A.Server` options for a request, such as `:generator`."
  @callback options() :: keyword()

  @doc """
  The agent's A2A agent card, which advertises its extensions and which
  `A2UIAgent.A2A.Plug` serves on `GET`.
  """
  @callback card() :: map()

  @optional_callbacks options: 0, card: 0
end

defmodule TerminalClient.Chat do
  @moduledoc """
  A conversation with the agent in the terminal: the user's steps go
  out over a transport, the agent's answers are applied to a
  `TerminalClient.Renderer` and the surfaces are drawn as text.

  Steps are what a user does:

    * `{:say, text}` — type a message;
    * `{:click, label}` or `{:click, label, nth}` — press a button;
    * `{:type, label, value}` — fill in an input.

  What the renderer has to tell the agent afterwards (function calls,
  answers to the agent's function calls, errors) goes out on its own,
  until the agent has nothing more to add.
  """

  alias TerminalClient.{Renderer, Text, Transport}

  defstruct [:transport, :state, :renderer, :name, :print, drawn: %{}]

  @type step ::
          {:say, String.t()}
          | {:click, String.t()}
          | {:click, String.t(), non_neg_integer()}
          | {:type, String.t(), term()}

  @max_rounds 5

  @doc """
  Connects to the agent. Options: `:transport` (a name of
  `TerminalClient.Transport.all/0`, default `"a2a"`), `:url` (the
  agent's base URL), `:version` (`"v1.0"` or `"v0.9"`), `:stream`
  (A2A `message/stream`), `:print` (a function of a line; default
  `IO.puts/1`).
  """
  @spec connect(keyword()) :: {:ok, %__MODULE__{}} | {:error, term()}
  def connect(options) do
    name = Keyword.get(options, :transport, "a2a")
    module = Map.fetch!(Transport.all(), name)
    version = Keyword.get(options, :version, "v1.0")
    url = endpoint(name, Keyword.get(options, :url, "http://127.0.0.1:4001"))

    with {:ok, state} <- module.connect(url, Keyword.put(options, :version, version)) do
      {:ok,
       %__MODULE__{
         transport: module,
         state: state,
         renderer: Renderer.new(version),
         name: name,
         print: Keyword.get(options, :print, &IO.puts/1)
       }}
    end
  end

  defp endpoint("a2a", url), do: url <> "/a2a"
  defp endpoint("express", url), do: url <> "/a2a/express"
  defp endpoint("mcp", url), do: url <> "/mcp"
  defp endpoint("agui", url), do: url <> "/agui"
  defp endpoint("sse", url), do: url <> "/events"
  defp endpoint("ws", url), do: String.replace_prefix(url, "http", "ws") <> "/ws"

  @doc "Runs the steps in order; stops at the first one that fails."
  @spec run(%__MODULE__{}, [step()]) :: {:ok, %__MODULE__{}} | {:error, String.t(), %__MODULE__{}}
  def run(chat, steps) do
    Enum.reduce_while(steps, {:ok, chat}, fn step, {:ok, chat} ->
      case step(chat, step) do
        {:ok, chat} -> {:cont, {:ok, chat}}
        {:error, reason} -> {:halt, {:error, reason, chat}}
      end
    end)
  end

  @doc "Takes one step."
  @spec step(%__MODULE__{}, step()) :: {:ok, %__MODULE__{}} | {:error, String.t()}
  def step(chat, {:say, text}) do
    chat.print.("> " <> text)
    exchange(chat, [{:text, text}], 0)
  end

  def step(chat, {:click, label}), do: step(chat, {:click, label, 0})

  def step(chat, {:click, label, nth}) do
    chat.print.("> click #{inspect(label)}")

    with {:ok, renderer, outbound} <- Renderer.click(chat.renderer, label, nth) do
      exchange(%{chat | renderer: renderer}, Enum.map(outbound, &{:message, &1}), 0)
    end
  end

  def step(chat, {:type, label, value}) do
    chat.print.("> type #{inspect(label)} #{inspect(value)}")

    with {:ok, renderer, outbound} <- Renderer.type(chat.renderer, label, value) do
      chat = draw(%{chat | renderer: renderer})

      if outbound == [],
        do: {:ok, chat},
        else: exchange(chat, Enum.map(outbound, &{:message, &1}), 0)
    end
  end

  @doc "Draws the surfaces that changed since they were last drawn, and says which went away."
  @spec draw(%__MODULE__{}) :: %__MODULE__{}
  def draw(chat) do
    ids = Renderer.surface_ids(chat.renderer)
    drawn = Map.new(ids, &{&1, Text.render(chat.renderer, &1)})

    for {id, _lines} <- chat.drawn, not Map.has_key?(drawn, id), do: chat.print.("(#{id} closed)")

    for id <- ids, drawn[id] != chat.drawn[id] do
      chat.print.("")
      Enum.each(["[#{id}]" | drawn[id]], chat.print)
    end

    %{chat | drawn: drawn}
  end

  defp exchange(chat, inputs, round) when round < @max_rounds do
    {inputs, left_out} = Enum.split_with(inputs, &supported?(chat, &1))

    for {:message, message} <- left_out,
        do: chat.print.("(#{chat.name} does not carry #{kind(message)} back to the agent)")

    if inputs == [] do
      {:ok, chat}
    else
      metadata = Renderer.metadata(chat.renderer)

      case chat.transport.request(chat.state, inputs, metadata, &say(chat, &1)) do
        {:ok, state, outputs} ->
          {renderer, outbound} =
            Enum.reduce(outputs, {chat.renderer, []}, fn
              {:a2ui, messages}, {renderer, outbound} ->
                {renderer, more} = Renderer.apply(renderer, messages)
                {renderer, outbound ++ more}

              {:text, _text}, acc ->
                acc
            end)

          chat = draw(%{chat | state: state, renderer: renderer})
          exchange(chat, Enum.map(outbound, &{:message, &1}), round + 1)

        {:error, reason} ->
          {:error, to_string(reason)}
      end
    end
  end

  defp exchange(chat, _inputs, _round), do: {:ok, chat}

  defp supported?(_chat, {:text, _text}), do: true
  defp supported?(chat, {:message, message}), do: chat.transport.supports?(message)

  defp say(chat, {:text, text}),
    do: if(String.trim(text) != "", do: chat.print.("agent: " <> String.trim(text)))

  defp say(_chat, _output), do: :ok

  defp kind(message), do: message |> Map.delete("version") |> Map.keys() |> hd()

  @doc """
  Reads a step written as a command-line argument: `click:LABEL`
  (`click:LABEL#2` for the third one), `type:LABEL=VALUE`, or text to
  say.
  """
  @spec parse(String.t()) :: step()
  def parse("click:" <> label) do
    case Regex.run(~r/\A(.*)#(\d+)\z/, label) do
      [_, label, nth] -> {:click, label, String.to_integer(nth)}
      nil -> {:click, label}
    end
  end

  def parse("type:" <> assignment) do
    [label, value] = String.split(assignment, "=", parts: 2)
    {:type, label, value}
  end

  def parse(text), do: {:say, text}
end

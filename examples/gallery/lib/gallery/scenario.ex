defmodule Gallery.Scenario do
  @moduledoc """
  A scenario of the gallery: a scripted agent that shows some features
  of A2UI.

  It has the messages it starts with, and answers what the renderer
  sends it (actions, function calls, function responses, errors) with
  more messages, after a delay, as a real agent would. Controls on the
  page make it act on its own, and a scenario can push updates on a
  timer.

      defmodule Gallery.Scenarios.Hello do
        use Gallery.Scenario

        def id, do: "hello"
        def title, do: "Hello"
        def summary, do: "A text."
        def features, do: ["Text"]

        def messages,
          do: [create("main", components: [%{"id" => "root", "component" => "Text", "text" => "Hi"}])]
      end
  """

  @typedoc """
  An answer: after `delay_ms`, the agent sends `payload` (a message, a
  list of them, `{:text, text}` for something it says, or
  `{:text_delta, text}` for more of what it is saying).
  """
  @type reply ::
          {non_neg_integer(), map() | [map()] | {:text, String.t()} | {:text_delta, String.t()}}

  @doc "The id in the scenario's URL."
  @callback id() :: String.t()
  @doc "The title."
  @callback title() :: String.t()
  @doc "What it shows, in a sentence or two."
  @callback summary() :: String.t()
  @doc "The A2UI features it exercises."
  @callback features() :: [String.t()]
  @doc "The catalogs of the renderer."
  @callback catalogs() :: [A2UICore.Catalog.t()]
  @doc "Options for `A2UIPhoenix.Session.new/2`."
  @callback session_options() :: keyword()
  @doc "Function components for the scenario's own component types."
  @callback components() :: %{optional(String.t()) => (map() -> Phoenix.LiveView.Rendered.t())}
  @doc "The agent's first messages."
  @callback messages() :: [map()]
  @doc "What the agent sends on its own once the page is connected."
  @callback start() :: [reply()]
  @doc "The agent's answer to a message from the renderer."
  @callback reply(message :: map()) :: [reply()]
  @doc """
  The agent's answer to a message from the renderer, given the data
  models that travel with it (the surfaces created with `sendDataModel`,
  by surface id). Defaults to `c:reply/1`.
  """
  @callback reply(message :: map(), data_models :: %{optional(String.t()) => term()}) :: [reply()]
  @doc "Buttons that make the agent act: `{id, label}`."
  @callback controls() :: [{String.t(), String.t()}]
  @doc "What the agent does for a control."
  @callback control(id :: String.t()) :: [reply()]
  @doc "Messages to push on the `n`-th tick, if the scenario ticks."
  @callback tick(n :: pos_integer()) :: [map()] | nil
  @doc "What the Script tab shows, when not the first messages."
  @callback script() :: String.t() | nil

  defmacro __using__(_options) do
    quote do
      @behaviour Gallery.Scenario

      import Gallery.Scenario.Messages

      @impl true
      def catalogs, do: [Gallery.Catalogs.basic("v1.0"), Gallery.Catalogs.restaurant()]

      @impl true
      def session_options, do: []

      @impl true
      def components, do: %{}

      @impl true
      def start, do: []

      @impl true
      def reply(_message), do: []

      @impl true
      def reply(message, _data_models), do: reply(message)

      @impl true
      def controls, do: []

      @impl true
      def control(_id), do: []

      @impl true
      def tick(_n), do: nil

      @impl true
      def script, do: nil

      defoverridable catalogs: 0,
                     session_options: 0,
                     components: 0,
                     start: 0,
                     reply: 1,
                     reply: 2,
                     controls: 0,
                     control: 1,
                     tick: 1,
                     script: 0
    end
  end

  @scenarios [
    Gallery.Scenarios.Components,
    Gallery.Scenarios.Forms,
    Gallery.Scenarios.Data,
    Gallery.Scenarios.Surfaces,
    Gallery.Scenarios.Functions,
    Gallery.Scenarios.CustomCatalog,
    Gallery.Scenarios.Streaming,
    Gallery.Scenarios.MCP,
    Gallery.Scenarios.Errors,
    Gallery.Scenarios.V09
  ]

  @doc "Every scenario, in the order of the index page."
  def all, do: @scenarios

  @doc "The scenario with `id`, or `nil`."
  def get(id), do: Enum.find(@scenarios, &(&1.id() == id))
end

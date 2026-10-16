defmodule TerminalClient.Renderer do
  @moduledoc """
  A renderer built on `a2ui_core` alone: no Phoenix, no processes, every
  step a function from the renderer's state to the next state and the
  messages for the agent.

  It holds an `A2UICore.Processor` for the surfaces and an
  `A2UICore.Resolution.NodeResolver` for each surface's tree, and does
  what a renderer owes the agent:

    * reports the messages it cannot apply (`error`);
    * answers the agent's `callRendererFunction` (the processor runs the
      function; `clientInfo` is this renderer's);
    * sends the function calls its catalogs cannot run to the agent
      (`callAgentFunction`) and puts the answers into the tree;
    * turns clicks into `action` messages and typing into data model
      writes.
  """

  alias A2UICore.{Catalog, Error, Processor}
  alias A2UICore.Catalog.Basic
  alias A2UICore.Message.RendererToAgent
  alias A2UICore.Resolution.{Binding, Node, NodeResolver}

  defstruct processor: nil, resolvers: %{}, calls: %{}, clock: nil, version: "v1.0"

  @type t :: %__MODULE__{
          processor: Processor.t(),
          resolvers: %{optional(String.t()) => NodeResolver.t()},
          calls: %{optional(String.t()) => {String.t(), term()}},
          clock: (-> DateTime.t()),
          version: String.t()
        }

  @restaurant_path Path.expand("../../../catalogs/restaurant_catalog.json", __DIR__)
  @external_resource @restaurant_path
  @restaurant_document File.read!(@restaurant_path)

  @doc """
  A renderer for protocol `version` (`"v1.0"`: the basic and restaurant
  catalogs; `"v0.9"`: the basic catalog). Option: `:clock`.
  """
  @spec new(String.t(), keyword()) :: t()
  def new(version \\ "v1.0", options \\ []) do
    %__MODULE__{
      processor: Processor.new(catalogs(version)),
      clock: Keyword.get(options, :clock, &DateTime.utc_now/0),
      version: version
    }
  end

  defp catalogs("v1.0"), do: [Basic.catalog("v1.0"), restaurant()]
  defp catalogs(_v09), do: [Basic.catalog("v0.9.1")]

  # The restaurant catalog, with the one function this renderer runs.
  defp restaurant do
    @restaurant_document
    |> Jason.decode!(objects: :ordered_objects)
    |> Catalog.from_json!()
    |> Catalog.put_implementations(%{
      "clientInfo" => fn _args, _context ->
        {:ok, %{"renderer" => "terminal", "locale" => "en-US", "timeZone" => time_zone()}}
      end
    })
  end

  defp time_zone, do: System.get_env("TZ") || "Etc/UTC"

  @doc """
  The metadata a message to the agent carries: the renderer's
  capabilities and the data models of the surfaces that asked for theirs.
  """
  @spec metadata(t()) :: map()
  def metadata(%__MODULE__{} = renderer) do
    versions = if renderer.version == "v1.0", do: ["v1.0"], else: ["v0.9"]
    {:ok, capabilities} = Processor.renderer_capabilities(renderer.processor, versions: versions)
    {:ok, data_model} = Processor.renderer_data_model(renderer.processor, nil)
    key = if renderer.version == "v1.0", do: "a2uiRenderer", else: "a2uiClient"

    %{(key <> "Capabilities") => capabilities}
    |> then(&if data_model, do: Map.put(&1, key <> "DataModel", data_model), else: &1)
  end

  @doc "The ids of the surfaces, newest last."
  @spec surface_ids(t()) :: [String.t()]
  def surface_ids(%__MODULE__{processor: processor}),
    do: processor |> Processor.surfaces() |> Enum.map(& &1.id)

  @doc "The resolved tree of a surface."
  @spec resolver(t(), String.t()) :: NodeResolver.t() | nil
  def resolver(%__MODULE__{resolvers: resolvers}, surface_id), do: Map.get(resolvers, surface_id)

  @doc "The surface `surface_id`."
  @spec surface(t(), String.t()) :: A2UICore.State.Surface.t() | nil
  def surface(%__MODULE__{processor: processor}, surface_id),
    do: Processor.surface(processor, surface_id)

  # -- agent messages ---------------------------------------------------------

  @doc """
  Applies agent messages. Returns the renderer and the messages for the
  agent: errors, function responses and agent function calls.
  """
  @spec apply(t(), [map()]) :: {t(), [map()]}
  def apply(%__MODULE__{} = renderer, messages) do
    case Processor.process(renderer.processor, messages) do
      {:ok, processor, effects} ->
        renderer |> Map.put(:processor, processor) |> after_effects(effects)

      {:error, %Error{} = error, processor} ->
        renderer = %{renderer | processor: processor}
        {renderer, outbound} = refresh_all(renderer)
        {renderer, outbound ++ [report(error, renderer.version)]}
    end
  end

  defp report(%Error{} = error, version) do
    options = if error.surface_id, do: [surface_id: error.surface_id], else: []
    RendererToAgent.error(error.code, error.message, [version: version] ++ options)
  end

  defp after_effects(renderer, effects) do
    deleted = for {:surface_deleted, id} <- effects, do: id
    renderer = %{renderer | resolvers: Map.drop(renderer.resolvers, deleted)}

    touched =
      effects
      |> Enum.flat_map(fn
        {:surface_created, id} -> [id]
        {:components_updated, id, _ids} -> [id]
        {:data_model_updated, id, _path} -> [id]
        _other -> []
      end)
      |> Enum.uniq()

    {renderer, outbound} = Enum.reduce(touched, {renderer, []}, &refresh/2)
    responses = for {:rpc_response, message} <- effects, do: message
    {renderer, settled} = settle(renderer, effects)
    {renderer, outbound ++ responses ++ settled}
  end

  # After a failed batch any surface may have changed, and some may be gone.
  defp refresh_all(renderer) do
    ids = surface_ids(renderer)
    Enum.reduce(ids, {%{renderer | resolvers: Map.take(renderer.resolvers, ids)}, []}, &refresh/2)
  end

  # Resolves a surface again and sends the agent calls its tree needs.
  defp refresh(surface_id, {renderer, outbound}) do
    surface = surface(renderer, surface_id)

    {resolver, notifications} =
      case Map.fetch(renderer.resolvers, surface_id) do
        {:ok, resolver} -> NodeResolver.update(resolver, surface)
        :error -> NodeResolver.new(surface)
      end

    renderer = put_in(renderer.resolvers[surface_id], resolver)

    Enum.reduce(notifications, {renderer, outbound}, fn
      {:agent_call, %{key: key, call: call}}, {renderer, outbound} ->
        {renderer, message} = call_agent(renderer, surface_id, key, call)
        {renderer, outbound ++ message}

      _other, acc ->
        acc
    end)
  end

  defp call_agent(renderer, surface_id, key, call) do
    case Processor.call_agent_function(renderer.processor, surface_id, call) do
      {:ok, processor, message} ->
        id = message["callAgentFunction"]["functionCallId"]

        {%{
           renderer
           | processor: processor,
             calls: Map.put(renderer.calls, id, {surface_id, key})
         }, [message]}

      {:error, _error} ->
        {renderer, []}
    end
  end

  # The agent answered: the value goes into the tree that asked for it.
  defp settle(renderer, effects) do
    Enum.reduce(effects, {renderer, []}, fn
      {:rpc_settled, id, outcome}, {renderer, outbound} ->
        case Map.pop(renderer.calls, id) do
          {{surface_id, key}, calls}
          when is_map_key(renderer.resolvers, surface_id) and key != nil ->
            outcome =
              with {:error, error} <- outcome,
                   do: {:error, %{code: error.code, message: error.message}}

            resolver =
              NodeResolver.settle_agent_call(renderer.resolvers[surface_id], key, outcome)

            renderer = %{
              renderer
              | calls: calls,
                resolvers: Map.put(renderer.resolvers, surface_id, resolver)
            }

            refresh(surface_id, {renderer, outbound})

          {_gone, calls} ->
            {%{renderer | calls: calls}, outbound}
        end

      _other, acc ->
        acc
    end)
  end

  # -- user input ---------------------------------------------------------------

  @doc """
  Clicks the button labelled `label` (the newest surface that has one
  first; `nth` counts the buttons with that label). Returns the messages
  for the agent, or an error when there is no such button or its checks
  fail.
  """
  @spec click(t(), String.t(), non_neg_integer()) :: {:ok, t(), [map()]} | {:error, String.t()}
  def click(%__MODULE__{} = renderer, label, nth \\ 0) do
    with {:ok, surface_id, node} <- find(renderer, label, nth, &button?/2),
         :ok <- enabled(node) do
      surface = surface(renderer, surface_id)
      resolver = resolver(renderer, surface_id)

      {:ok, interactions} =
        NodeResolver.invoke(resolver, surface, node.ref, "action", renderer.clock.())

      {renderer, outbound} = interact(renderer, surface_id, interactions)
      {:ok, renderer, outbound}
    end
  end

  defp enabled(%Node{props: %{"isValid" => false}}),
    do: {:error, "The button is disabled: its checks fail."}

  defp enabled(_node), do: :ok

  defp interact(renderer, surface_id, interactions) do
    Enum.reduce(interactions, {renderer, []}, fn
      {:action_event, event}, {renderer, outbound} ->
        version = surface(renderer, surface_id).version
        {renderer, outbound ++ [RendererToAgent.action(event, version: version)]}

      {:agent_call, %{action: true, call: call}}, {renderer, outbound} ->
        {renderer, message} = call_agent(renderer, surface_id, nil, call)
        {renderer, outbound ++ message}

      {:write, %{path: path, value: value}}, {renderer, outbound} ->
        {renderer, more} = write(renderer, surface_id, path, value)
        {renderer, outbound ++ more}

      _other, acc ->
        acc
    end)
  end

  @doc """
  Types `value` into the input labelled `label`: a text field, a check
  box, a slider, a date-time input, or a choice (the option labelled
  `value`). Returns the messages for the agent: agent function calls whose
  arguments changed.
  """
  @spec type(t(), String.t(), term()) :: {:ok, t(), [map()]} | {:error, String.t()}
  def type(%__MODULE__{} = renderer, label, value) do
    with {:ok, surface_id, node} <- find(renderer, label, 0, &input?/2),
         {:ok, path, value} <-
           NodeResolver.write(
             resolver(renderer, surface_id),
             node.ref,
             "value",
             convert(node, value)
           ) do
      {renderer, outbound} = write(renderer, surface_id, path, value)
      {:ok, renderer, outbound}
    else
      {:error, %Error{message: message}} -> {:error, message}
      {:error, message} -> {:error, message}
    end
  end

  defp write(renderer, surface_id, path, value) do
    case Processor.set_data(renderer.processor, surface_id, path, value) do
      {:ok, processor, effects} -> after_effects(%{renderer | processor: processor}, effects)
      {:error, _error} -> {renderer, []}
    end
  end

  # What a user types is text; the input decides what it becomes.
  defp convert(%Node{type: "Slider"}, value) when is_binary(value), do: number(value)

  defp convert(%Node{type: "CheckBox"}, value) when is_binary(value),
    do: value in ["true", "yes", "x", "on"]

  defp convert(%Node{type: "ChoicePicker", props: props}, value) when is_binary(value) do
    option =
      Enum.find(props["options"] || [], &(text(&1["label"]) == value or &1["value"] == value))

    [if(option, do: option["value"], else: value)]
  end

  defp convert(_node, value), do: value

  defp number(text) do
    case Float.parse(text) do
      {number, ""} -> if number == trunc(number), do: trunc(number), else: number
      _other -> text
    end
  end

  defp find(renderer, label, nth, matches?) do
    found =
      for surface_id <- Enum.reverse(surface_ids(renderer)),
          resolver = resolver(renderer, surface_id),
          resolver != nil,
          {_position, node} <- resolver |> NodeResolver.positions() |> Enum.sort(),
          matches?.(node, {resolver, label}),
          do: {surface_id, node}

    case Enum.at(found, nth) do
      {surface_id, node} -> {:ok, surface_id, node}
      nil -> {:error, "Nothing labelled #{inspect(label)} on screen."}
    end
  end

  defp button?(%Node{type: "Button", props: props}, {resolver, label}) do
    case props["child"] do
      {:node, ref} -> label_of(NodeResolver.node(resolver, ref), resolver) == label
      _none -> false
    end
  end

  defp button?(_node, _wanted), do: false

  defp input?(%Node{type: type, props: props}, {_resolver, label})
       when type in ["TextField", "CheckBox", "Slider", "DateTimeInput", "ChoicePicker"],
       do: text(props["label"]) == label

  defp input?(_node, _wanted), do: false

  @doc "The text a node shows: its `text`, or the text of its child."
  @spec label_of(Node.t() | nil, NodeResolver.t()) :: String.t() | nil
  def label_of(%Node{props: %{"text" => text}}, _resolver), do: text(text)

  def label_of(%Node{props: %{"child" => {:node, ref}}}, resolver),
    do: label_of(NodeResolver.node(resolver, ref), resolver)

  def label_of(_node, _resolver), do: nil

  @doc "The value of a resolved property."
  @spec text(term()) :: term()
  def text(%Binding{value: value}), do: value
  def text(value), do: value
end

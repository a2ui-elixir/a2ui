defmodule A2UIPhoenix.Session do
  @moduledoc """
  The renderer side of one A2UI conversation: the surfaces an agent built
  (an `A2UICore.Processor`) and, for each surface, its resolved component
  tree (an `A2UICore.Resolution.NodeResolver`).

  A session is plain data owned by the host — usually a LiveView assign
  (see `A2UIPhoenix.Live`). Every operation returns the new session
  together with the effects the host acts on:

    * `{:send, message}` — a renderer→agent message (`action`, `error`,
      `rendererFunctionResponse`) to deliver to the agent;
    * `{:open_url, url}` — an `openUrl` action asks the browser to open
      `url` (the scheme was checked by the catalog function);
    * `{:surface_created, id}`, `{:surface_deleted, id}`,
      `{:components_updated, id, component_ids}`,
      `{:data_model_updated, id, path}` — as the processor reports them;
    * `{:rpc_settled, call_id, outcome}` — a pending agent call settled;
    * `{:diagnostic, surface_id, :error | :warning, payload}` — what the
      resolver found while resolving or invoking (an unknown component
      type, a cyclic reference, a binding that does not resolve).

  Agent messages go through `handle_message/3`; user input goes through
  `write/5` (a two-way binding) and `invoke/4` (an action).

      session = A2UIPhoenix.Session.new([A2UICore.Catalog.Basic.catalog("v1.0")])
      {:ok, session, _effects} = A2UIPhoenix.Session.handle_message(session, message)
  """

  alias A2UICore.{Catalog, Error, Processor}
  alias A2UICore.Message.RendererToAgent
  alias A2UICore.Resolution.{Action, DataContext, Node, NodeResolver}
  alias A2UICore.State.Surface

  @moduledoc since: "0.1.0"

  @enforce_keys [:processor]
  defstruct processor: nil, resolvers: %{}, version: "v1.0", clock: nil

  @type t :: %__MODULE__{
          processor: Processor.t(),
          resolvers: %{optional(String.t()) => NodeResolver.t()},
          version: String.t(),
          clock: (-> DateTime.t()) | nil
        }

  @type effect ::
          {:send, map()}
          | {:open_url, String.t()}
          | {:diagnostic, String.t(), :error | :warning, map()}
          | Processor.effect()

  @validation_codes ["VALIDATION_FAILED", "UNALLOWED_PARENT", "UNALLOWED_CHILD"]

  @doc """
  Creates a session over `catalogs` (the first one is the default for
  surfaces that name none).

  Options:

    * `:validation` and `:default_timeout_ms` — passed to
      `A2UICore.Processor.new/2`;
    * `:version` — the protocol version of outbound messages when the
      surface does not decide it (`"v1.0"`);
    * `:clock` — a zero-arity function returning the current
      `DateTime`, used for action timestamps (`DateTime.utc_now/0`).
  """
  @spec new([Catalog.t()], keyword()) :: t()
  def new(catalogs, options \\ []) do
    %__MODULE__{
      processor:
        Processor.new(catalogs, Keyword.take(options, [:validation, :default_timeout_ms])),
      version: Keyword.get(options, :version, "v1.0"),
      clock: options[:clock]
    }
  end

  # -- reading ------------------------------------------------------------------

  @doc "The surface with `id`, or `nil`."
  @spec surface(t(), String.t()) :: Surface.t() | nil
  def surface(%__MODULE__{processor: processor}, id), do: Processor.surface(processor, id)

  @doc "All surfaces, sorted by id."
  @spec surfaces(t()) :: [Surface.t()]
  def surfaces(%__MODULE__{processor: processor}), do: Processor.surfaces(processor)

  @doc "The resolved tree of surface `id`, or `nil`."
  @spec resolver(t(), String.t()) :: NodeResolver.t() | nil
  def resolver(%__MODULE__{resolvers: resolvers}, id), do: Map.get(resolvers, id)

  @doc """
  The data models of the surfaces created with `sendDataModel`, for the
  transport to attach to outbound messages; see
  `A2UICore.Processor.renderer_data_model/2`.
  """
  @spec client_data_model(t(), String.t() | nil) :: {:ok, map() | nil} | {:error, Error.t()}
  def client_data_model(%__MODULE__{processor: processor}, version \\ nil),
    do: Processor.renderer_data_model(processor, version)

  # -- agent messages -----------------------------------------------------------

  @doc """
  Applies an agent payload (a message, a list, or a `{"messages": …}`
  wrapper) and re-resolves the surfaces it touched.

  On failure the operations before the failing one stay applied (see
  `A2UICore.Processor.process/3`); the effects then include the `error`
  message to report to the agent when the error names a surface or a
  function call. Options are passed to the processor (`:user_activated`,
  `:surface_id`).
  """
  @spec handle_message(t(), term(), keyword()) ::
          {:ok, t(), [effect()]} | {:error, Error.t(), t(), [effect()]}
  def handle_message(%__MODULE__{} = session, payload, options \\ []) do
    case Processor.process(session.processor, payload, options) do
      {:ok, processor, effects} ->
        {session, notes} = sync(%{session | processor: processor}, effects)
        {:ok, session, outbound(effects) ++ notes}

      {:error, error, processor} ->
        session = %{session | processor: processor}
        {session, notes} = sync(session, all_surfaces_touched(session))
        {:error, error, session, notes ++ error_report(session, error, payload)}
    end
  end

  defp outbound(effects) do
    Enum.map(effects, fn
      {:rpc_response, message} -> {:send, message}
      effect -> effect
    end)
  end

  # Without the effects of a failed batch, every surface may have changed
  # and any may be gone.
  defp all_surfaces_touched(session) do
    gone = for {id, _resolver} <- session.resolvers, surface(session, id) == nil, do: id

    Enum.map(gone, &{:surface_deleted, &1}) ++
      Enum.map(surfaces(session), &{:components_updated, &1.id, []})
  end

  defp error_report(session, %Error{} = error, payload) do
    surface_id = error.surface_id || payload_surface(payload)
    version = surface_version(session, surface_id)

    options =
      cond do
        error.code in @validation_codes and is_binary(surface_id) ->
          [surface_id: surface_id, path: error.path || "/"]

        is_binary(error.function_call_id) ->
          [function_call_id: error.function_call_id]

        is_binary(surface_id) ->
          [surface_id: surface_id]

        true ->
          nil
      end

    if options,
      do: [
        {:send, RendererToAgent.error(error.code, error.message, [version: version] ++ options)}
      ],
      else: []
  end

  # The surface a payload is about, when it is about exactly one.
  defp payload_surface(payload) do
    case payload |> payload_messages() |> Enum.flat_map(&message_surface/1) |> Enum.uniq() do
      [id] -> id
      _none_or_many -> nil
    end
  end

  defp payload_messages(%{"messages" => messages}) when is_list(messages), do: messages
  defp payload_messages(messages) when is_list(messages), do: messages
  defp payload_messages(message), do: [message]

  defp message_surface(%{} = message) do
    for {key, %{"surfaceId" => id}} <- message, key != "version", is_binary(id), do: id
  end

  defp message_surface(_other), do: []

  # -- user input ---------------------------------------------------------------

  @doc """
  Writes `value` through `property` of node `ref` on surface `surface_id`
  — a two-way binding receiving user input — and re-resolves the surface.

  Returns an error when the node is gone or the property is not bound to
  a data path.
  """
  @spec write(t(), String.t(), pos_integer(), String.t(), term()) ::
          {:ok, t(), [effect()]} | {:error, Error.t()}
  def write(%__MODULE__{} = session, surface_id, ref, property, value) do
    with {:ok, resolver} <- fetch_resolver(session, surface_id),
         {:ok, path, value} <- NodeResolver.write(resolver, ref, property, value),
         {:ok, processor, effects} <-
           Processor.set_data(session.processor, surface_id, path, value) do
      {session, notes} = sync(%{session | processor: processor}, effects)
      {:ok, session, effects ++ notes}
    end
  end

  @doc """
  Invokes the action in `property` of node `ref` on surface `surface_id`.

  An event action produces `{:send, action_message}`; an `openUrl`
  function call produces `{:open_url, url}`; any other function call runs
  in the renderer. A component whose checks fail (`isValid` is `false`)
  does not act.
  """
  @spec invoke(t(), String.t(), pos_integer(), String.t()) ::
          {:ok, t(), [effect()]} | {:error, Error.t()}
  def invoke(%__MODULE__{} = session, surface_id, ref, property) do
    with {:ok, resolver} <- fetch_resolver(session, surface_id),
         {:ok, node} <- fetch_enabled_node(resolver, ref),
         surface = surface(session, surface_id),
         {:ok, interactions} <-
           NodeResolver.invoke(resolver, surface, ref, property, now(session)) do
      version = surface.version || session.version

      effects =
        Enum.map(interactions, fn
          {:action_event, event} -> {:send, RendererToAgent.action(event, version: version)}
          {level, payload} -> {:diagnostic, surface_id, level, payload}
        end)

      {:ok, session, effects ++ open_url(surface, node, property, interactions)}
    end
  end

  defp fetch_enabled_node(resolver, ref) do
    case NodeResolver.node(resolver, ref) do
      %Node{props: %{"isValid" => false}} = node ->
        {:error,
         Error.new(
           :state,
           "COMPONENT_INVALID",
           "Component '#{node.component_id}' does not act while its checks fail."
         )}

      %Node{} = node ->
        {:ok, node}

      nil ->
        {:error, Error.new(:state, "NODE_NOT_FOUND", "No mounted node with reference #{ref}.")}
    end
  end

  defp open_url(surface, node, property, interactions) do
    with %Action{definition: %{"functionCall" => %{} = call}} <- Map.get(node.props, property),
         "openUrl" <- call["@call"] || call["call"],
         false <- Enum.any?(interactions, &match?({:error, _}, &1)),
         context = DataContext.for_surface(surface, path: node.data_path),
         {%{"url" => url}, _effects} <-
           DataContext.resolve_dynamic_value(context, Map.get(call, "args", %{})),
         true <- is_binary(url) and String.trim(url) != "" do
      [{:open_url, url}]
    else
      _not_an_open -> []
    end
  end

  # -- lifecycle ----------------------------------------------------------------

  @doc """
  Rejects the pending agent calls and drops every resolved tree; the
  surfaces stay readable.
  """
  @spec dispose(t()) :: {t(), [effect()]}
  def dispose(%__MODULE__{} = session) do
    {processor, effects} = Processor.dispose(session.processor)
    {%{session | processor: processor, resolvers: %{}}, effects}
  end

  # -- resolution ---------------------------------------------------------------

  # Brings the resolvers in line with the surfaces the effects touched:
  # a deleted surface loses its tree, a created or changed one is
  # (re)resolved.
  defp sync(session, effects) do
    deleted = for {:surface_deleted, id} <- effects, uniq: true, do: id
    touched = effects |> Enum.flat_map(&touched/1) |> Enum.uniq()

    session = %{session | resolvers: Map.drop(session.resolvers, deleted)}
    Enum.reduce(touched, {session, []}, &refresh/2)
  end

  defp touched({:surface_created, id}), do: [id]
  defp touched({:components_updated, id, _ids}), do: [id]
  defp touched({:data_model_updated, id, _path}), do: [id]
  defp touched(_effect), do: []

  defp refresh(id, {session, notes}) do
    case surface(session, id) do
      nil ->
        {%{session | resolvers: Map.delete(session.resolvers, id)}, notes}

      surface ->
        {resolver, notifications} =
          case Map.fetch(session.resolvers, id) do
            {:ok, resolver} -> NodeResolver.update(resolver, surface)
            :error -> NodeResolver.new(surface)
          end

        diagnostics =
          for {level, payload} <- notifications,
              level in [:error, :warning],
              do: {:diagnostic, id, level, payload}

        {%{session | resolvers: Map.put(session.resolvers, id, resolver)}, notes ++ diagnostics}
    end
  end

  defp fetch_resolver(session, surface_id) do
    case resolver(session, surface_id) do
      nil ->
        {:error,
         Error.new(:integrity, "INTEGRITY_ERROR", "Surface not found: #{surface_id}",
           surface_id: surface_id
         )}

      resolver ->
        {:ok, resolver}
    end
  end

  defp surface_version(session, surface_id) do
    case surface_id && surface(session, surface_id) do
      %Surface{version: version} when is_binary(version) -> version
      _none -> session.version
    end
  end

  defp now(%__MODULE__{clock: nil}), do: DateTime.utc_now()
  defp now(%__MODULE__{clock: clock}), do: clock.()
end

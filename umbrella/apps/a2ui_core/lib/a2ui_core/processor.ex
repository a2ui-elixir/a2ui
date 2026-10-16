defmodule A2UICore.Processor do
  @moduledoc """
  Applies agent→renderer messages to a set of surfaces.

  A processor is plain data: `process/2` takes a processor and a raw
  payload (a message, a list of messages, a `{"messages": [...]}`
  wrapper) and returns the updated processor together with the effects a
  host may react to. Nothing is delivered by callback and no process is
  involved; the host owns the processor value.

      catalog = A2UICore.Catalog.Basic.catalog("v0.9")
      processor = A2UICore.Processor.new([catalog])

      {:ok, processor, effects} =
        A2UICore.Processor.process(processor, %{
          "version" => "v0.9",
          "createSurface" => %{"surfaceId" => "main", "catalogId" => catalog.catalog_id}
        })

  ## Semantics

  Messages are decoded (`A2UICore.Message.decode/2`) and their operations
  applied in order. There is no rollback across operations: when one
  fails, the operations before it stay applied and `process/2` returns
  `{:error, error, processor}` with that partially updated processor.
  Within one `updateComponents` the update is atomic — a failing batch
  leaves the surface untouched.

    * `createSurface` — the surface's default catalog is the one named
      by `catalogId`. A v1.0 surface may name none and then has no
      default catalog; before v1.0 the processor's first catalog is the
      fallback. The message's version must be compatible with the catalog
      (`A2UICore.Version`) and a theme is validated against it. The
      surface can use every catalog of its protocol version. Inline
      `dataModel` and `components` are applied right after the surface is
      created.
    * `updateComponents` — each component takes the catalog named by its
      `catalogId`, else the one it already has (when its type is
      unchanged), else the surface's default; from v1.0 a component that
      names none on a surface without a default catalog is an error, and
      so is a function call nested in it whose catalog does not resolve.
      With a validation configuration the batch is validated as a whole
      before it is committed (`A2UICore.Validation.ComponentsUpdate`).
    * `updateDataModel` — writes into the surface's data model.
    * `deleteSurface` — removes the surface; an unknown id is ignored.
    * `callRendererFunction` — runs the function (see `A2UICore.RPC`)
      against the data of the surface its `surfaceId` names, or of no
      surface when it names none, and comes back as an
      `{:rpc_response, message}` effect: the `rendererFunctionResponse` to
      send to the agent. Calls that require user activation need the
      `:user_activated` option.
    * `agentFunctionResponse` — settles the pending agent call it answers
      and comes back as an `{:rpc_settled, call_id, outcome}` effect.
      Neither changes surface state.

  Without a validation configuration (`:validation` option) component
  batches are committed unchecked.

  ## Effects

    * `{:surface_created, surface_id}`
    * `{:surface_deleted, surface_id}`
    * `{:components_updated, surface_id, component_ids}`
    * `{:data_model_updated, surface_id, path}`
    * `{:rpc_response, message}`
    * `{:rpc_settled, call_id, {:ok, value} | {:error, error}}`

  ## Calling the agent

  `call_agent_function/4` registers a call and returns the
  `callAgentFunction` message. The call is settled by an
  `agentFunctionResponse` message, by `timeout_agent_call/2` when the
  host's timer for it fires, by `cancel_agent_call/3`, or by `dispose/1`;
  the settlements come back as `{:rpc_settled, …}` effects.
  """

  alias A2UICore.{Catalog, Error, Message, RPC, SemVer, Version}
  alias A2UICore.Error.Detail
  alias A2UICore.Message.Operation

  alias A2UICore.Message.Operation.{
    AgentFunctionResponse,
    CallRendererFunction,
    CreateSurface,
    DeleteSurface,
    UpdateComponents,
    UpdateDataModel
  }

  alias A2UICore.Resolution.DataContext
  alias A2UICore.State.{Component, Components, Surface, SurfaceGroup}
  alias A2UICore.Validation.{ComponentsUpdate, Config, NestedCalls, Payload}

  @moduledoc since: "0.1.0"

  @enforce_keys [:catalogs]
  defstruct catalogs: [], group: nil, validation: nil, rpc: nil

  @type t :: %__MODULE__{
          catalogs: [Catalog.t()],
          group: SurfaceGroup.t(),
          validation: Config.t() | nil,
          rpc: RPC.t()
        }

  @type effect ::
          {:surface_created, String.t()}
          | {:surface_deleted, String.t()}
          | {:components_updated, String.t(), [String.t()]}
          | {:data_model_updated, String.t(), String.t()}
          | {:rpc_response, map()}
          | {:rpc_settled, String.t(), {:ok, term()} | {:error, Error.t()}}

  @default_envelope_ref "common_types.json#/$defs/ComponentCommon"

  @doc """
  Creates a processor over `catalogs`. The first catalog is the default
  for surfaces that name none.

  Options: `:validation` — an `A2UICore.Validation.Config` applied to
  component batches (none by default); `:default_timeout_ms` — the
  timeout of agent calls that name none (30 000).

  Raises `ArgumentError` when `catalogs` is empty.
  """
  @spec new([Catalog.t()], keyword()) :: t()
  def new(catalogs, options \\ [])

  def new([], _options), do: raise(ArgumentError, "At least one catalog must be provided.")

  def new([%Catalog{} | _] = catalogs, options) do
    # Linking returns copies, so catalogs shared with other processors
    # never see this processor's peers.
    catalogs = Catalog.link_catalogs(catalogs)

    %__MODULE__{
      catalogs: catalogs,
      group: SurfaceGroup.new(),
      validation: options[:validation],
      rpc: RPC.new(catalogs, Keyword.take(options, [:default_timeout_ms]))
    }
  end

  @doc "The surface with `id`, or `nil`."
  @spec surface(t(), String.t()) :: Surface.t() | nil
  def surface(%__MODULE__{group: group}, id), do: SurfaceGroup.get(group, id)

  @doc "All surfaces, sorted by id."
  @spec surfaces(t()) :: [Surface.t()]
  def surfaces(%__MODULE__{group: group}), do: SurfaceGroup.to_list(group)

  # -- calling the agent ----------------------------------------------------------

  @doc """
  Registers a call to an agent function on `surface_id` and returns the
  `callAgentFunction` message to send; see `A2UICore.RPC.call_agent_function/4`
  for the call and its options.
  """
  @spec call_agent_function(t(), String.t(), map(), keyword()) ::
          {:ok, t(), map()} | {:error, Error.t()}
  def call_agent_function(%__MODULE__{} = processor, surface_id, call, options \\ []) do
    with {:ok, rpc, message} <- RPC.call_agent_function(processor.rpc, surface_id, call, options) do
      {:ok, %{processor | rpc: rpc}, message}
    end
  end

  @doc """
  The timeout, in milliseconds, of a pending agent call: the host starts a
  timer for it and reports the expiry with `timeout_agent_call/2`.
  `nil` for a call that is not pending or has no timeout.
  """
  @spec agent_call_timeout(t(), String.t()) :: number() | nil
  def agent_call_timeout(%__MODULE__{rpc: rpc}, call_id), do: RPC.pending_timeout(rpc, call_id)

  @doc "Rejects a pending agent call whose timer fired, with `TIMEOUT`."
  @spec timeout_agent_call(t(), String.t()) :: {t(), [effect()]}
  def timeout_agent_call(%__MODULE__{} = processor, call_id),
    do: settle_with(processor, &RPC.timeout(&1, call_id))

  @doc "Rejects a pending agent call the host abandoned, with `CANCELLED`."
  @spec cancel_agent_call(t(), String.t(), String.t()) :: {t(), [effect()]}
  def cancel_agent_call(%__MODULE__{} = processor, call_id, reason \\ "The call was cancelled."),
    do: settle_with(processor, &RPC.cancel(&1, call_id, reason))

  @doc """
  Rejects every pending agent call with `CANCELLED` and stops answering
  function calls. Surfaces are left as they are.
  """
  @spec dispose(t()) :: {t(), [effect()]}
  def dispose(%__MODULE__{} = processor), do: settle_with(processor, &RPC.dispose/1)

  defp settle_with(processor, fun) do
    {rpc, settlements} = fun.(processor.rpc)
    {%{processor | rpc: rpc}, settled(settlements)}
  end

  # -- processing ---------------------------------------------------------------

  @doc """
  Decodes `payload` and applies its operations in order.

  Returns `{:ok, processor, effects}`, or `{:error, error, processor}`
  where `processor` holds whatever was applied before the failure.

  Options: `:user_activated` — the messages are processed inside a user
  gesture (functions that require activation run only then).
  """
  @spec process(t(), term(), keyword()) :: {:ok, t(), [effect()]} | {:error, Error.t(), t()}
  def process(%__MODULE__{} = processor, payload, options \\ []) do
    case Message.decode(payload, catalog: :permissive) do
      {:ok, operations} -> apply_operations(processor, operations, options)
      {:error, error} -> {:error, error, processor}
    end
  end

  @doc """
  Applies already-decoded operations in order, as `process/2` does.
  """
  @spec apply_operations(t(), [Operation.t()], keyword()) ::
          {:ok, t(), [effect()]} | {:error, Error.t(), t()}
  def apply_operations(%__MODULE__{} = processor, operations, options \\ []) do
    Enum.reduce_while(operations, {:ok, processor, []}, fn operation, {:ok, processor, effects} ->
      case apply_operation(processor, operation, options) do
        {:ok, processor, more} -> {:cont, {:ok, processor, effects ++ more}}
        {:error, _error, _processor} = failure -> {:halt, failure}
      end
    end)
  end

  @doc """
  Applies one operation.
  """
  @spec apply_operation(t(), Operation.t(), keyword()) ::
          {:ok, t(), [effect()]} | {:error, Error.t(), t()}
  def apply_operation(%__MODULE__{} = processor, operation, options \\ []) do
    case check_allowed(processor, operation) do
      :ok -> dispatch(processor, operation, options)
      {:error, error} -> {:error, error, processor}
    end
  end

  defp check_allowed(%__MODULE__{validation: %Config{allowed_messages: allowed}}, operation)
       when is_list(allowed) do
    action = Operation.action(operation)

    if action in allowed do
      :ok
    else
      {:error,
       Error.new(
         :validation,
         "INVALID_ACTION",
         "Message action '#{action}' is not allowed. Allowed actions: " <>
           "#{Enum.join(Enum.sort(allowed), ", ")}."
       )}
    end
  end

  defp check_allowed(_processor, _operation), do: :ok

  defp dispatch(processor, %CreateSurface{} = operation, _options),
    do: create_surface(processor, operation)

  defp dispatch(processor, %UpdateComponents{} = operation, _options),
    do: update_components(processor, operation)

  defp dispatch(processor, %UpdateDataModel{} = operation, _options),
    do: update_data_model(processor, operation)

  defp dispatch(processor, %DeleteSurface{surface_id: id}, _options) do
    {group, effects} = SurfaceGroup.delete(processor.group, id)
    {:ok, %{processor | group: group}, effects}
  end

  # A call that names a surface is resolved against that surface's data;
  # see `A2UICore.RPC.call_renderer_function/3`.
  defp dispatch(processor, %CallRendererFunction{} = operation, options) do
    surface = operation.surface_id && surface(processor, operation.surface_id)

    response =
      RPC.call_renderer_function(processor.rpc, operation,
        context: surface && DataContext.for_surface(surface),
        user_activated: options[:user_activated] == true
      )

    {:ok, processor, [{:rpc_response, response}]}
  end

  defp dispatch(processor, %AgentFunctionResponse{} = operation, _options) do
    {rpc, settlements} = RPC.handle_agent_function_response(processor.rpc, operation)
    {:ok, %{processor | rpc: rpc}, settled(settlements)}
  end

  defp settled(settlements) do
    for settlement <- settlements do
      case settlement do
        {:resolved, id, value} -> {:rpc_settled, id, {:ok, value}}
        {:rejected, id, error} -> {:rpc_settled, id, {:error, error}}
      end
    end
  end

  # Inner steps return `{:ok, processor, effects}` or `{:error, error}`;
  # the processor of a failure is the one the step started from.
  defp attempt(processor, result) do
    case result do
      {:ok, _processor, _effects} = ok -> ok
      {:error, error} -> {:error, error, processor}
      {:error, _error, _processor} = failure -> failure
    end
  end

  # -- createSurface ------------------------------------------------------------

  defp create_surface(processor, %CreateSurface{surface_id: id} = operation) do
    result =
      with {:ok, catalog} <- surface_catalog(processor, operation),
           :ok <- ensure_new(processor, id),
           theme = theme(operation.theme),
           :ok <- check_theme(catalog, id, theme),
           :ok <- check_version(catalog, operation) do
        surface = build_surface(processor, catalog, theme, operation)
        {group, effects} = SurfaceGroup.add(processor.group, surface)
        created = %{processor | group: group}

        case apply_inline(created, operation) do
          {:ok, created, more} -> {:ok, created, effects ++ more}
          {:error, error} -> {:error, error, created}
        end
      end

    attempt(processor, result)
  end

  # The surface's default catalog. From v1.0 it is optional: a surface
  # that names none has none, and every component and function call on
  # it names its own. Before v1.0 the first catalog is the fallback.
  defp surface_catalog(processor, %CreateSurface{catalog_id: nil} = operation) do
    if v1?(operation.version),
      do: {:ok, nil},
      else: {:ok, hd(processor.catalogs)}
  end

  defp surface_catalog(processor, %CreateSurface{catalog_id: catalog_id}) do
    case find_catalog(processor, catalog_id) do
      nil -> {:error, catalog_not_found(catalog_id)}
      catalog -> {:ok, catalog}
    end
  end

  defp v1?(version) when is_binary(version), do: SemVer.at_least(version, "v1.0")
  defp v1?(_version), do: false

  defp find_catalog(%__MODULE__{catalogs: catalogs}, catalog_id),
    do: Enum.find(catalogs, &(&1.catalog_id == catalog_id))

  defp catalog_not_found(catalog_id),
    do: Error.new(:catalog, "CATALOG_ERROR", "Catalog not found: #{catalog_id}")

  defp ensure_new(processor, id) do
    if SurfaceGroup.has?(processor.group, id) do
      {:error,
       Error.new(:integrity, "INTEGRITY_ERROR", "Surface #{id} already exists.", surface_id: id)}
    else
      :ok
    end
  end

  defp theme(theme) when theme in [nil, false, 0, "", [], %{}], do: %{}
  defp theme(theme), do: theme

  defp check_theme(_catalog, _id, theme) when theme == %{}, do: :ok
  defp check_theme(nil, _id, _theme), do: :ok

  defp check_theme(catalog, id, theme) do
    case Payload.validate_theme(catalog, theme) do
      :ok ->
        :ok

      {:error, %Error{} = error} ->
        {:error,
         Error.new(
           :validation,
           "VALIDATION_FAILED",
           "Validation failed for theme on surface '#{id}': #{error.message}",
           surface_id: id,
           details: error.details
         )}
    end
  end

  defp check_version(nil, _operation), do: :ok

  defp check_version(%Catalog{protocol_version: catalog_version} = catalog, operation) do
    message_version = operation.version

    if catalog_version && message_version &&
         not Version.catalog_compatible?(catalog_version, message_version) do
      name = operation.catalog_id || catalog.catalog_id

      {:error,
       Error.new(
         :validation,
         "VERSION_MISMATCH",
         "Surface '#{operation.surface_id}' catalog '#{name}' specification version " <>
           "(#{catalog_version}) does not match message protocol version (#{message_version}).",
         surface_id: operation.surface_id
       )}
    else
      :ok
    end
  end

  defp build_surface(processor, catalog, theme, operation) do
    version = if catalog, do: catalog.protocol_version, else: operation.version
    default = if catalog, do: %{catalog.catalog_id => catalog}, else: %{}

    available =
      for candidate <- processor.catalogs,
          Version.catalog_compatible?(candidate.protocol_version, version),
          into: default,
          do: {candidate.catalog_id, candidate}

    Surface.new(operation.surface_id,
      catalog_id: catalog && catalog.catalog_id,
      catalogs: available,
      theme: theme,
      send_data_model: operation.send_data_model,
      root_id: operation.root || "root",
      version: operation.version
    )
  end

  defp apply_inline(processor, %CreateSurface{} = operation) do
    id = operation.surface_id

    with {:ok, processor, data_effects} <- inline_data(processor, id, operation.data_model),
         {:ok, processor, component_effects} <-
           inline_components(processor, id, operation.components) do
      {:ok, processor, data_effects ++ component_effects}
    end
  end

  defp inline_data(processor, _id, nil), do: {:ok, processor, []}

  defp inline_data(processor, id, value),
    do: write_data(processor, id, "/", value)

  defp inline_components(processor, _id, nil), do: {:ok, processor, []}

  defp inline_components(processor, id, components),
    do: commit_components(processor, id, components)

  # -- updateComponents ---------------------------------------------------------

  defp update_components(processor, %UpdateComponents{} = operation),
    do:
      attempt(processor, commit_components(processor, operation.surface_id, operation.components))

  defp commit_components(processor, surface_id, components) do
    with {:ok, surface} <- fetch_surface(processor, surface_id),
         :ok <- ensure_list(components),
         {:ok, incoming} <- build_components(processor, surface, components),
         :ok <- check_update(processor, surface, incoming) do
      merged = Enum.reduce(incoming, surface.components, &Components.put(&2, &1))
      surface = Surface.put_components(surface, merged)

      {:ok, %{processor | group: SurfaceGroup.update(processor.group, surface)},
       [{:components_updated, surface_id, Enum.map(incoming, & &1.id)}]}
    end
  end

  defp fetch_surface(processor, id) do
    case SurfaceGroup.get(processor.group, id) do
      nil ->
        {:error,
         Error.new(:integrity, "INTEGRITY_ERROR", "Surface not found for message: #{id}",
           surface_id: id
         )}

      surface ->
        {:ok, surface}
    end
  end

  defp ensure_list(components) when is_list(components), do: :ok

  defp ensure_list(_other),
    do:
      {:error, Error.new(:validation, "VALIDATION_FAILED", "Components payload must be a list.")}

  defp build_components(processor, surface, raw_components) do
    raw_components
    |> Enum.reduce_while({:ok, []}, fn raw, {:ok, built} ->
      case build_component(processor, surface, raw) do
        {:ok, component} -> {:cont, {:ok, [component | built]}}
        {:error, _error} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, built} -> {:ok, Enum.reverse(built)}
      {:error, _error} = error -> error
    end
  end

  defp build_component(processor, surface, raw) do
    v1? = v1?(Surface.protocol_version(surface))

    with {:ok, id} <- component_id(raw),
         existing = Components.get(surface.components, id),
         {:ok, type} <- component_type(raw, existing, id, v1?),
         {:ok, catalog} <- component_catalog(processor, surface, raw, existing, v1?) do
      properties = Map.drop(raw, ["id", "component", "catalogId"])
      {:ok, Component.new(id, type, properties, catalog_id: catalog.catalog_id)}
    end
  end

  defp component_id(%{"id" => id}) when is_binary(id) and id != "", do: {:ok, id}

  defp component_id(_raw) do
    {:error,
     Error.new(
       :validation,
       "VALIDATION_FAILED",
       "Component update payload is missing an 'id' / missing required 'id' field."
     )}
  end

  # From v1.0 every component in `updateComponents` names its type, as
  # the specification's `Component` schema requires, so an update cannot
  # leave out the type of the component it replaces.
  defp component_type(raw, existing, id, v1?) do
    case {raw["component"], existing} do
      {type, _existing} when is_binary(type) and type != "" ->
        {:ok, type}

      {_none, nil} ->
        {:error,
         Error.new(
           :validation,
           "VALIDATION_FAILED",
           "Cannot create component #{id} without a type."
         )}

      {_none, %Component{}} when v1? ->
        {:error,
         Error.new(
           :validation,
           "VALIDATION_FAILED",
           "Component #{id} is missing the required 'component' field.",
           details: [
             Detail.new(
               "missing_field",
               "'component' is a required property",
               "components.#{id}.component"
             )
           ]
         )}

      {_none, %Component{type: type}} ->
        {:ok, type}
    end
  end

  # The catalog a component runs in: the one it names (from v1.0 any
  # string, an empty one included, names a catalog; before v1.0 only a
  # non-empty value does), else, before v1.0, the catalog of the
  # component it replaces, else the surface's default catalog.
  defp component_catalog(processor, surface, raw, existing, v1?) do
    catalog_id = raw["catalogId"]

    cond do
      v1? and not is_nil(catalog_id) and not is_binary(catalog_id) ->
        non_string_catalog(raw["id"])

      names_catalog?(catalog_id, v1?) ->
        resolve_component_catalog(processor, surface, raw)

      true ->
        unnamed_component_catalog(surface, raw, existing, v1?)
    end
  end

  defp unnamed_component_catalog(surface, raw, existing, v1?) do
    default = Surface.default_catalog(surface)

    cond do
      not v1? and existing != nil and raw["component"] in [nil, "", existing.type] ->
        {:ok, Map.get(surface.catalogs, existing.catalog_id) || default}

      default != nil ->
        {:ok, default}

      true ->
        {:error,
         Error.new(
           :catalog,
           "CATALOG_ERROR",
           "Component #{raw["id"]} names no catalogId and surface #{surface.id} has no " <>
             "default catalogId."
         )}
    end
  end

  defp names_catalog?(catalog_id, true), do: not is_nil(catalog_id)
  defp names_catalog?(catalog_id, false), do: catalog_id not in [nil, false, "", 0]

  defp non_string_catalog(id) do
    {:error,
     Error.new(
       :validation,
       "VALIDATION_FAILED",
       "Component #{id} has a non-string 'catalogId'.",
       details: [
         Detail.new("type_mismatch", "'catalogId' must be a string", "components.#{id}.catalogId")
       ]
     )}
  end

  defp resolve_component_catalog(processor, surface, raw) do
    catalog_id = raw["catalogId"]

    with %Catalog{} = catalog <- find_catalog(processor, catalog_id) || :missing,
         :ok <- check_component_version(raw["id"], catalog, surface) do
      {:ok, catalog}
    else
      :missing -> {:error, catalog_not_found(catalog_id)}
      {:error, _error} = error -> error
    end
  end

  defp check_component_version(id, %Catalog{} = catalog, surface) do
    surface_version = Surface.protocol_version(surface)

    if catalog.protocol_version && surface_version &&
         not Version.catalog_compatible?(catalog.protocol_version, surface_version) do
      {:error,
       Error.new(
         :catalog,
         "CATALOG_ERROR",
         "Component #{id} catalog '#{catalog.catalog_id}' has different protocol version " <>
           "#{NestedCalls.label(catalog.protocol_version)} than surface #{surface.id} " <>
           "(#{NestedCalls.label(surface_version)})."
       )}
    else
      :ok
    end
  end

  # From v1.0 the nested-call pass runs first: a call whose catalog does
  # not resolve fails the batch at once, and its argument errors are
  # reported together with the component schema errors.
  defp check_update(processor, surface, incoming) do
    nested =
      if v1?(Surface.protocol_version(surface)),
        do: NestedCalls.check(surface, incoming, processor.catalogs, processor.validation),
        else: :ok

    case nested do
      {:error, %Error{category: :catalog}} = error ->
        error

      :ok ->
        validate_update(processor, surface, incoming)

      {:error, nested_error} ->
        case validate_update(processor, surface, incoming) do
          {:error, %Error{category: :validation} = error} ->
            {:error, NestedCalls.merge(nested_error, error)}

          _ok_or_other ->
            {:error, nested_error}
        end
    end
  end

  defp validate_update(%__MODULE__{validation: nil}, _surface, _incoming), do: :ok

  defp validate_update(%__MODULE__{validation: %Config{} = config}, surface, incoming) do
    config = %{config | root_id: surface.root_id}
    default = Surface.default_catalog(surface)

    catalog_for = fn %Component{catalog_id: id} -> Map.get(surface.catalogs, id) || default end

    ComponentsUpdate.validate(surface.components, incoming, catalog_for, config,
      default_catalog_id: surface.catalog_id
    )
  end

  # -- updateDataModel ----------------------------------------------------------

  @doc """
  Writes `value` at `path` of a surface's data model on the renderer's
  behalf — user input reaching a two-way binding. It is the same write as
  an `updateDataModel` message, but not one the agent sent, so the
  validation configuration's `allowed_messages` does not apply.

  Returns `{:ok, processor, [{:data_model_updated, surface_id, path}]}`,
  or `{:error, error}` for an unknown surface or an invalid path.
  """
  @spec set_data(t(), String.t(), String.t(), term()) ::
          {:ok, t(), [effect()]} | {:error, Error.t()}
  def set_data(%__MODULE__{} = processor, surface_id, path, value),
    do: write_data(processor, surface_id, path, value)

  defp update_data_model(processor, %UpdateDataModel{} = operation) do
    path = if operation.path in [nil, ""], do: "/", else: operation.path
    attempt(processor, write_data(processor, operation.surface_id, path, operation.value))
  end

  defp write_data(processor, surface_id, path, value) do
    with {:ok, surface} <- fetch_surface(processor, surface_id),
         {:ok, surface, _notifications} <- Surface.set_data(surface, path, value) do
      {:ok, %{processor | group: SurfaceGroup.update(processor.group, surface)},
       [{:data_model_updated, surface_id, path}]}
    end
  end

  # -- renderer capabilities ----------------------------------------------------

  @doc """
  The renderer capabilities for the processor's catalogs, keyed by
  protocol version.

  Options:

    * `:versions` — the protocol versions to describe (required);
    * `:include_inline_catalogs` — add each catalog's definition under
      `"inlineCatalogs"`: its document (`A2UICore.Catalog.to_json/2`)
      from v1.0 on, else a legacy inline catalog whose components are
      `allOf` envelopes over `:component_envelope_ref` (default
      `#{@default_envelope_ref}`), built from the resolved schemas.

  Returns `{:error, error}` when no version is given.
  """
  @spec renderer_capabilities(t(), keyword()) :: {:ok, map()} | {:error, Error.t()}
  def renderer_capabilities(%__MODULE__{catalogs: catalogs}, options) do
    versions = for version <- List.wrap(options[:versions]), version not in [nil, ""], do: version

    if versions == [] do
      {:error,
       Error.new(
         :validation,
         "VALIDATION_FAILED",
         "At least one protocol version must be provided in CapabilitiesOptions " <>
           "to generate renderer capabilities."
       )}
    else
      inline? = options[:include_inline_catalogs] == true
      envelope = options[:component_envelope_ref] || @default_envelope_ref

      {:ok,
       Map.new(versions, fn version ->
         {to_string(version), version_capabilities(catalogs, version, inline?, envelope)}
       end)}
    end
  end

  defp version_capabilities(catalogs, version, inline?, envelope) do
    capabilities = %{"supportedCatalogIds" => Enum.map(catalogs, & &1.catalog_id)}

    if inline? do
      inline = Enum.map(catalogs, &inline_catalog(&1, to_string(version), envelope))
      Map.put(capabilities, "inlineCatalogs", inline)
    else
      capabilities
    end
  end

  defp inline_catalog(catalog, version, envelope) do
    if SemVer.at_least(version, "v1.0"),
      do: Catalog.to_json(catalog),
      else: legacy_inline_catalog(catalog, envelope)
  end

  defp legacy_inline_catalog(%Catalog{} = catalog, envelope) do
    %{"catalogId" => catalog.catalog_id}
    |> put_present("components", legacy_components(catalog, envelope))
    |> put_present("functions", legacy_functions(catalog))
    |> put_present("theme", legacy_theme(Catalog.resolved_theme_schema(catalog)))
  end

  defp put_present(map, _key, value) when value in [%{}, [], nil], do: map
  defp put_present(map, key, value), do: Map.put(map, key, value)

  defp legacy_components(catalog, envelope) do
    Map.new(catalog.components, fn {name, _component} ->
      schema = map_or_empty(Catalog.resolved_component_schema(catalog, name))
      properties = schema |> Map.get("properties", %{}) |> Map.drop(["id", "component"])
      required = schema |> Map.get("required", []) |> Enum.reject(&(&1 in ["id", "component"]))

      {name,
       %{
         "allOf" => [
           %{"$ref" => envelope},
           %{
             "properties" => Map.put(properties, "component", %{"const" => name}),
             "required" => ["component" | required]
           }
         ]
       }}
    end)
  end

  defp legacy_functions(catalog) do
    Enum.map(catalog.function_order, fn name ->
      function = catalog.functions[name]
      schema = map_or_empty(Catalog.resolved_function_schema(catalog, name))

      %{"name" => name}
      |> put_present("description", function.description || description(schema))
      |> Map.put("returnType", function.return_type || schema["returnType"] || "any")
      |> Map.put("parameters", parameters(schema))
    end)
  end

  defp map_or_empty(%{} = schema), do: schema
  defp map_or_empty(_schema), do: %{}

  defp description(%{"description" => description}) when is_binary(description), do: description
  defp description(_schema), do: nil

  defp parameters(%{"parameters" => %{} = parameters}), do: parameters
  defp parameters(%{"properties" => %{"args" => %{} = args}}), do: args
  defp parameters(schema) when schema == %{}, do: %{"type" => "object", "properties" => %{}}
  defp parameters(schema), do: schema

  defp legacy_theme(theme) when not is_map(theme) or map_size(theme) == 0, do: nil
  defp legacy_theme(%{"properties" => properties}), do: properties
  defp legacy_theme(theme), do: theme

  # -- renderer data model ------------------------------------------------------

  @doc """
  The data models of the surfaces that asked for them (`sendDataModel`),
  as `%{"version" => …, "surfaces" => %{id => data}}`, or `nil` when no
  surface did.

  With `version`, only surfaces whose catalog is compatible with it are
  included. Without, the version is the one all such surfaces share
  (`"v1.0"` when none declares one); surfaces on different versions are
  an error.
  """
  @spec renderer_data_model(t(), String.t() | nil) :: {:ok, map() | nil} | {:error, Error.t()}
  def renderer_data_model(%__MODULE__{group: group}, version \\ nil) do
    enabled = group |> SurfaceGroup.to_list() |> Enum.filter(& &1.send_data_model)

    cond do
      enabled == [] -> {:ok, nil}
      version != nil -> {:ok, data_models(enabled, to_string(version))}
      true -> data_models_by_surface_version(enabled)
    end
  end

  defp data_models(surfaces, version) do
    compatible =
      Enum.filter(surfaces, fn surface ->
        case Surface.protocol_version(surface) do
          surface_version when is_binary(surface_version) ->
            Version.catalog_compatible?(surface_version, version)

          _none ->
            true
        end
      end)

    if compatible == [],
      do: nil,
      else: %{"version" => version, "surfaces" => root_data(compatible)}
  end

  defp data_models_by_surface_version(surfaces) do
    versions =
      surfaces
      |> Enum.map(&Surface.protocol_version/1)
      |> Enum.flat_map(fn
        version when is_binary(version) -> [NestedCalls.label(version)]
        _none -> []
      end)
      |> Enum.uniq()
      |> Enum.sort()

    case versions do
      [_, _ | _] ->
        {:error,
         Error.new(
           :validation,
           "VALIDATION_FAILED",
           "Multiple protocol versions detected among active surfaces: " <>
             "[#{Enum.map_join(versions, ", ", &"'#{&1}'")}]. Specify a target protocol " <>
             "version in get_renderer_data_model(version)."
         )}

      _single_or_none ->
        {:ok, %{"version" => List.first(versions) || "v1.0", "surfaces" => root_data(surfaces)}}
    end
  end

  defp root_data(surfaces) do
    Map.new(surfaces, fn surface ->
      {:ok, data} = Surface.get_data(surface, "/")
      {surface.id, data}
    end)
  end
end

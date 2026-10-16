defmodule A2UICore.RPC do
  @moduledoc """
  The function RPC of protocol v1.0, as a value.

  Two directions meet here.

  **The agent calls a renderer function** (`callRendererFunction`).
  `call_renderer_function/3` resolves the function in the catalog the
  call names, checks that an agent may call it, resolves its arguments
  against the data of the surface the call names (or against an empty
  data model), validates them, runs it and returns the
  `rendererFunctionResponse` message to send back. It always returns
  one: every failure is an error response, never an exception.

  **The renderer calls an agent function** (`callAgentFunction`).
  `call_agent_function/4` registers a pending call and returns the
  message to send. The call is settled later, by one of:

    * `handle_agent_function_response/2` — the agent answered;
    * `timeout/2` — the host's timer for the call fired;
    * `cancel/3` and `dispose/2` — the host gave up.

  Each of these returns the settlements it caused:
  `{:resolved, call_id, value}` or `{:rejected, call_id, error}`.

  Nothing here runs a process or reads a clock. A call's timeout is data
  (`pending_timeout/2`): the host starts a timer for it and reports it
  with `timeout/2`.

  ## Error codes

  Responses and rejections use `INVALID_FUNCTION_CALL` (an unknown
  surface, catalog or function, a caller or activation violation, bad
  arguments, a malformed call), `EXECUTION_ERROR` (the function failed,
  or an argument's expression did), `TIMEOUT`, `CANCELLED`, `DISPOSED`,
  `DUPLICATE` and `UNKNOWN_ERROR` (an agent error without a code).
  """

  alias A2UICore.{Catalog, Error, Version}
  alias A2UICore.Catalog.Function
  alias A2UICore.Message.Operation.{AgentFunctionResponse, CallRendererFunction}
  alias A2UICore.Message.RendererToAgent
  alias A2UICore.Resolution.DataContext
  alias A2UICore.State.DataModel
  alias A2UICore.Validation.Payload

  @moduledoc since: "0.1.0"

  @default_timeout_ms 30_000
  @disposed_message "RpcHandler has been disposed."

  @enforce_keys [:catalogs]
  defstruct catalogs: [],
            pending: %{},
            default_timeout_ms: @default_timeout_ms,
            next_id: 1,
            disposed?: false

  @type pending :: %{name: String.t(), timeout_ms: number() | nil}

  @type t :: %__MODULE__{
          catalogs: [Catalog.t()],
          pending: %{optional(String.t()) => pending()},
          default_timeout_ms: number(),
          next_id: pos_integer(),
          disposed?: boolean()
        }

  @type settlement ::
          {:resolved, String.t(), term()}
          | {:rejected, String.t(), Error.t()}

  @doc """
  Creates the handler over `catalogs`, the catalogs functions are
  resolved in.

  Options: `:default_timeout_ms` (default 30 000) for calls that name no
  timeout of their own; zero or less means no timeout.

  Raises `ArgumentError` when `catalogs` is empty.
  """
  @spec new([Catalog.t()], keyword()) :: t()
  def new(catalogs, options \\ [])

  def new([], _options),
    do: raise(ArgumentError, "At least one catalog must be provided to RPC.")

  def new(catalogs, options) when is_list(catalogs) do
    %__MODULE__{
      catalogs: catalogs,
      default_timeout_ms: Keyword.get(options, :default_timeout_ms, @default_timeout_ms)
    }
  end

  @doc "Whether the handler has been disposed."
  @spec disposed?(t()) :: boolean()
  def disposed?(%__MODULE__{disposed?: disposed?}), do: disposed?

  @doc "The ids of the calls still waiting for the agent, sorted."
  @spec pending(t()) :: [String.t()]
  def pending(%__MODULE__{pending: pending}), do: pending |> Map.keys() |> Enum.sort()

  @doc """
  The timeout of a pending call in milliseconds, or `nil` when the call
  is not pending or has none. The host's timer is the one that fires it.
  """
  @spec pending_timeout(t(), String.t()) :: number() | nil
  def pending_timeout(%__MODULE__{pending: pending}, call_id) do
    case Map.get(pending, call_id) do
      %{timeout_ms: timeout_ms} -> timeout_ms
      nil -> nil
    end
  end

  # -- agent calls a renderer function ------------------------------------------

  @doc """
  Executes an agent's `callRendererFunction` and returns the
  `rendererFunctionResponse` message.

  The function runs in the catalog the call names (`catalogId`). Its
  arguments are resolved against `:context`, the data context of the
  surface the call names (`surfaceId`); a call that names no surface
  runs in a context of its own, with an empty data model and the call's
  catalog as its default catalog. An argument whose expression fails
  makes the call fail with `EXECUTION_ERROR`; the resolved arguments are
  then validated against the function's schema.

  Options:

    * `:context` — the `A2UICore.Resolution.DataContext` of the surface
      the call names (`nil` when there is no such surface, which fails the
      call);
    * `:user_activated` — whether the call happens inside a user gesture,
      which functions that require activation need (default `false`).
  """
  @spec call_renderer_function(t(), CallRendererFunction.t(), keyword()) :: map()
  def call_renderer_function(%__MODULE__{} = rpc, %CallRendererFunction{} = call, options \\ []) do
    outcome =
      with :ok <- ensure_live(rpc),
           :ok <- check_surface(call, options[:context]),
           {:ok, catalog} <- resolve_catalog(rpc, call),
           :ok <- check_version(catalog, call),
           {:ok, function} <- find_function(catalog, call),
           :ok <- check_permissions(function, call, options[:user_activated] == true),
           context = options[:context] || own_context(rpc, catalog, call, options),
           {:ok, resolved} <- resolve_arguments(call.args, context),
           {:ok, arguments} <- validate_arguments(catalog, call.call, resolved) do
        execute(function, arguments, context)
      end

    RendererToAgent.function_response(call.function_call_id, outcome, version: call.version)
  end

  defp ensure_live(%__MODULE__{disposed?: true}), do: {:error, "DISPOSED", @disposed_message}
  defp ensure_live(%__MODULE__{}), do: :ok

  defp check_surface(%CallRendererFunction{surface_id: nil}, _context), do: :ok
  defp check_surface(%CallRendererFunction{surface_id: id}, %DataContext{surface_id: id}), do: :ok

  defp check_surface(%CallRendererFunction{surface_id: id}, _context),
    do: {:error, "INVALID_FUNCTION_CALL", "Surface not found: #{id}"}

  defp resolve_catalog(rpc, %CallRendererFunction{catalog_id: id})
       when is_binary(id) and id != "" do
    case Enum.find(rpc.catalogs, &(&1.catalog_id == id)) do
      nil -> {:error, "INVALID_FUNCTION_CALL", "Catalog not found: #{id}"}
      catalog -> {:ok, catalog}
    end
  end

  defp resolve_catalog(_rpc, _call),
    do: {:error, "INVALID_FUNCTION_CALL", "No catalog available for function resolution."}

  # The surface-independent root context of a call that names no surface.
  defp own_context(rpc, catalog, call, options) do
    DataContext.new("/",
      data_model: DataModel.new(%{}),
      catalog: catalog,
      catalogs: Map.new(rpc.catalogs, &{&1.catalog_id, &1}),
      surface_id: "_rpc_fallback_#{call.function_call_id || "default"}",
      user_activated: options[:user_activated] == true
    )
  end

  # Each argument is resolved on its own; the first expression error
  # fails the call.
  defp resolve_arguments(args, %DataContext{} = context) when is_map(args) do
    Enum.reduce_while(args, {:ok, %{}}, fn {key, value}, {:ok, acc} ->
      {resolved, effects} = DataContext.resolve_dynamic_value(context, value)

      case Enum.find(effects, &match?({:error, %{code: "EXPRESSION_ERROR"}}, &1)) do
        nil -> {:cont, {:ok, Map.put(acc, key, resolved)}}
        {:error, error} -> {:halt, {:error, "EXECUTION_ERROR", error.message}}
      end
    end)
  end

  defp resolve_arguments(args, _context), do: {:ok, args}

  defp check_version(%Catalog{protocol_version: catalog_version}, %CallRendererFunction{} = call) do
    if catalog_version && call.version &&
         not Version.catalog_compatible?(catalog_version, call.version) do
      {:error, "INVALID_FUNCTION_CALL",
       "Catalog specification version (#{catalog_version}) does not match " <>
         "message protocol version (#{call.version})."}
    else
      :ok
    end
  end

  defp find_function(catalog, %CallRendererFunction{call: name}) do
    case Catalog.get_function(catalog, name) do
      nil -> {:error, "INVALID_FUNCTION_CALL", "Function not found: #{name}"}
      function -> {:ok, function}
    end
  end

  # A function that does not say who may call it is renderer-only.
  defp check_permissions(%Function{} = function, %CallRendererFunction{call: name}, activated?) do
    allowed = function.allowed_callers || "rendererOnly"

    cond do
      allowed not in ["agentOnly", "rendererOrAgent"] ->
        {:error, "INVALID_FUNCTION_CALL",
         "Function '#{name}' cannot be called by agent (allowedCallers is #{allowed})."}

      function.requires_user_activation == true and not activated? ->
        {:error, "INVALID_FUNCTION_CALL",
         "Function '#{name}' requires user activation context to execute."}

      true ->
        :ok
    end
  end

  defp validate_arguments(catalog, name, args) do
    case Payload.validate_function(catalog, name, args) do
      {:ok, arguments} ->
        {:ok, arguments}

      {:error, %Error{} = error} ->
        {:error, "INVALID_FUNCTION_CALL",
         "Invalid arguments for function '#{name}': #{Exception.message(error)}"}
    end
  end

  defp execute(%Function{name: name, execute: nil}, _arguments, _context) do
    {:error, "EXECUTION_ERROR", "Function '#{name}' is not callable and has no execute method."}
  end

  defp execute(%Function{execute: run}, arguments, context) do
    case run.(arguments, context) do
      {:ok, value} -> {:ok, value}
      {:ok, value, _effects} -> {:ok, value}
      {:error, error} -> {:error, "EXECUTION_ERROR", Exception.message(error)}
    end
  rescue
    exception -> {:error, "EXECUTION_ERROR", Exception.message(exception)}
  end

  # -- renderer calls an agent function -----------------------------------------

  @doc """
  Registers a call to an agent function and returns the
  `callAgentFunction` message to send.

  `call` is a function call object (`"@call"` or `"call"`, `"catalogId"`,
  `"args"`). Options: `:function_call_id` (a counter-based id otherwise),
  `:timeout_ms` (the handler's default otherwise) and `:version`.

  Fails with a `:rpc` error — `DISPOSED`, `INVALID_FUNCTION_CALL` for a
  call without a name, `DUPLICATE` for an id that is already pending.
  """
  @spec call_agent_function(t(), String.t(), map(), keyword()) ::
          {:ok, t(), map()} | {:error, Error.t()}
  def call_agent_function(%__MODULE__{} = rpc, surface_id, call, options \\ [])
      when is_binary(surface_id) and is_map(call) do
    name = call["@call"] || call["call"]
    {call_id, rpc} = call_id(rpc, options[:function_call_id])

    with :ok <- check_open(rpc),
         :ok <- check_name(name),
         :ok <- check_unused(rpc, call_id) do
      register(rpc, surface_id, call_id, name, call, options)
    end
  end

  defp check_open(%__MODULE__{disposed?: true}),
    do: {:error, rpc_error("DISPOSED", @disposed_message)}

  defp check_open(%__MODULE__{}), do: :ok

  defp check_name(name) when is_binary(name) and name != "", do: :ok

  defp check_name(_name),
    do: {:error, rpc_error("INVALID_FUNCTION_CALL", "Missing or invalid function call name.")}

  defp check_unused(%__MODULE__{pending: pending}, call_id) do
    if Map.has_key?(pending, call_id) do
      {:error,
       rpc_error("DUPLICATE", "A call with functionCallId '#{call_id}' is already pending.",
         function_call_id: call_id
       )}
    else
      :ok
    end
  end

  defp register(rpc, surface_id, call_id, name, call, options) do
    timeout_ms = Keyword.get(options, :timeout_ms) || rpc.default_timeout_ms
    entry = %{name: name, timeout_ms: if(timeout_ms > 0, do: timeout_ms)}
    wire_call = call |> Map.delete("call") |> Map.put("@call", name)

    message =
      RendererToAgent.call_agent_function(surface_id, call_id, wire_call,
        version: Keyword.get(options, :version, "v1.0")
      )

    {:ok, %{rpc | pending: Map.put(rpc.pending, call_id, entry)}, message}
  end

  defp call_id(rpc, nil), do: {"call-#{rpc.next_id}", %{rpc | next_id: rpc.next_id + 1}}
  defp call_id(rpc, id), do: {id, rpc}

  @doc """
  Settles the pending call an agent's `agentFunctionResponse` answers.
  A response to a call that is not pending is ignored.
  """
  @spec handle_agent_function_response(t(), AgentFunctionResponse.t()) ::
          {t(), [settlement()]}
  def handle_agent_function_response(%__MODULE__{} = rpc, %AgentFunctionResponse{} = response) do
    id = response.function_call_id

    case Map.pop(rpc.pending, id) do
      {nil, _pending} ->
        {rpc, []}

      {_entry, pending} ->
        {%{rpc | pending: pending}, [settle(id, response)]}
    end
  end

  defp settle(id, %AgentFunctionResponse{error: %{} = error}) do
    code = error["code"] || "UNKNOWN_ERROR"
    message = error["message"] || "Agent function execution failed"

    {:rejected, id,
     rpc_error(code, "Agent function error [#{code}]: #{message}", function_call_id: id)}
  end

  defp settle(id, %AgentFunctionResponse{value: value}), do: {:resolved, id, value}

  @doc """
  Rejects a pending call whose timer fired, with `TIMEOUT`. Ignored when
  the call is no longer pending.
  """
  @spec timeout(t(), String.t()) :: {t(), [settlement()]}
  def timeout(%__MODULE__{} = rpc, call_id) do
    case Map.pop(rpc.pending, call_id) do
      {nil, _pending} ->
        {rpc, []}

      {%{name: name, timeout_ms: timeout_ms}, pending} ->
        error =
          rpc_error("TIMEOUT", "Agent function call '#{name}' timed out after #{timeout_ms}ms.",
            function_call_id: call_id
          )

        {%{rpc | pending: pending}, [{:rejected, call_id, error}]}
    end
  end

  @doc """
  Rejects a pending call because the host abandoned it, with `CANCELLED`.
  Ignored when the call is no longer pending.
  """
  @spec cancel(t(), String.t(), String.t()) :: {t(), [settlement()]}
  def cancel(%__MODULE__{} = rpc, call_id, reason \\ "The call was cancelled.") do
    case Map.pop(rpc.pending, call_id) do
      {nil, _pending} ->
        {rpc, []}

      {_entry, pending} ->
        error = rpc_error("CANCELLED", reason, function_call_id: call_id)
        {%{rpc | pending: pending}, [{:rejected, call_id, error}]}
    end
  end

  @doc """
  Rejects every pending call with `CANCELLED` and stops the handler:
  later renderer-function calls answer `DISPOSED` and agent calls fail.
  Idempotent.
  """
  @spec dispose(t(), String.t()) :: {t(), [settlement()]}
  def dispose(rpc, reason \\ @disposed_message)

  def dispose(%__MODULE__{disposed?: true} = rpc, _reason), do: {rpc, []}

  def dispose(%__MODULE__{pending: pending} = rpc, reason) do
    settlements =
      for {id, _entry} <- Enum.sort(pending) do
        error =
          rpc_error(
            "CANCELLED",
            "RpcHandler disposed while call '#{id}' was pending: #{reason}",
            function_call_id: id
          )

        {:rejected, id, error}
      end

    {%{rpc | pending: %{}, disposed?: true}, settlements}
  end

  defp rpc_error(code, message, options \\ []), do: Error.new(:rpc, code, message, options)
end

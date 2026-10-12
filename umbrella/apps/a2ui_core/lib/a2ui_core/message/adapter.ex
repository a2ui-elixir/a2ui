defmodule A2UICore.Message.Adapter do
  @moduledoc """
  Version adapter behaviour and the shared envelope-extraction pipeline.

  Each protocol version implements the `c:Adapter` behaviour; the shared
  `extract/3` pipeline (a faithful port of the reference
  `BaseVersionAdapter.extract_operations`) drives them:

  1. recursion/pointer preflight (`A2UICore.Validation.Integrity`),
  2. payload unwrapping — `nil`/`[]` are no-ops, lists recurse per item
     (pre-checking the single-action rule for every item first), and
     `{"messages": [...]}` wrappers recurse into the list,
  3. per-message checks, in this order:
     exactly one action key (with the reference's two distinct error
     messages), action payload must be an object, `surfaceId` must be a
     string when present, `version` presence and compatibility,
  4. schema validation against the version's vendored envelope
     document — the message-type `$defs` entry selected by the action
     key (mirroring the reference's discriminated dispatch) with the
     active catalog bound to the `catalog.json` placeholder,
  5. operation construction via `c:extract_operations/2`.
  """

  alias A2UICore.Error
  alias A2UICore.Error.Detail
  alias A2UICore.Message.{Operation, AdapterRegistry}
  alias A2UICore.Schema
  alias A2UICore.Schema.Source
  alias A2UICore.SemVer
  alias A2UICore.Validation.Integrity

  @moduledoc since: "0.1.0"

  @typedoc "Adapter options: `:catalog` binds the active catalog schema."
  @type opts :: keyword()

  @doc """
  Extracts canonical operations from a raw payload using `adapter`.

  Returns `{:ok, operations}` or `{:error, error}`.
  """
  @spec extract(module(), term(), opts()) :: {:ok, [Operation.t()]} | {:error, Error.t()}
  def extract(adapter, payload, opts \\ []) do
    case payload do
      nil ->
        {:ok, []}

      [] ->
        {:ok, []}

      list when is_list(list) ->
        with :ok <- Integrity.validate_recursion_and_paths(list),
             :ok <- precheck_list_actions(adapter, list) do
          extract_list(adapter, list, opts, [])
        end

      wrapper when is_map(wrapper) ->
        case wrapper do
          %{"messages" => messages} when is_list(messages) ->
            extract(adapter, messages, opts)

          _message ->
            extract_single(adapter, wrapper, opts)
        end

      _scalar ->
        # The registry rejects scalars before dispatch; the reference
        # adapter also tolerates them as no-ops.
        {:ok, []}
    end
  end

  defp extract_list(_adapter, [], _opts, acc), do: {:ok, Enum.reverse(acc)}

  defp extract_list(adapter, [item | rest], opts, acc) do
    case extract(adapter, item, opts) do
      {:ok, ops} -> extract_list(adapter, rest, opts, ops ++ acc)
      {:error, error} -> {:error, error}
    end
  end

  defp precheck_list_actions(adapter, list) do
    Enum.reduce_while(list, :ok, fn
      item, :ok when is_map(item) ->
        case ensure_single_action(adapter, item) do
          {:ok, _action} -> {:cont, :ok}
          {:error, error} -> {:halt, {:error, error}}
        end

      _item, :ok ->
        {:cont, :ok}
    end)
  end

  # ------------------------------------------------------- single message --

  defp extract_single(adapter, message, opts) when is_map(message) do
    with {:ok, action} <- ensure_single_action(adapter, message),
         :ok <- ensure_payload_object(action, message),
         :ok <- check_message_version(adapter, message) do
      prepared = adapter.prepare_message(message)

      with :ok <- validate_message_schema(adapter, action, prepared, opts) do
        {:ok, adapter.extract_operations(action, message)}
      end
    end
  end

  @spec ensure_single_action(module(), map()) :: {:ok, String.t()} | {:error, Error.t()}
  defp ensure_single_action(adapter, message) do
    valid = adapter.valid_actions()
    present = valid |> Enum.filter(&Map.has_key?(message, &1)) |> Enum.sort()

    cond do
      length(present) > 1 ->
        {:error,
         Error.new(
           :validation,
           "INVALID_ACTION",
           "Message contains multiple conflicting update actions: #{Enum.join(present, ", ")}."
         )}

      present == [] ->
        not_supported_error(adapter, message)

      true ->
        [action] = present

        case message[action] do
          payload when is_map(payload) ->
            with :ok <- ensure_surface_id_string(payload) do
              {:ok, action}
            end

          _non_map ->
            {:ok, action}
        end
    end
  end

  defp not_supported_error(adapter, message) do
    version = adapter.version()
    other = Enum.find(message, fn {key, _} -> key in AdapterRegistry.all_known_actions() end)

    if other do
      {:error,
       Error.new(
         :validation,
         "INVALID_ACTION",
         "Invalid #{version} message: action '#{elem(other, 0)}' is not supported in" <>
           " protocol version #{version}. Allowed actions:" <>
           " #{Enum.join(Enum.sort(adapter.valid_actions()), ", ")}."
       )}
    else
      {:error,
       Error.new(
         :validation,
         "INVALID_ACTION",
         "Invalid #{version} message: message must contain exactly one update action:" <>
           " #{Enum.join(Enum.sort(adapter.valid_actions()), ", ")}."
       )}
    end
  end

  defp ensure_surface_id_string(payload) do
    case payload do
      %{"surfaceId" => surface_id} when not is_binary(surface_id) ->
        {:error, Error.new(:validation, "INVALID_SURFACE_ID", "surfaceId must be a string")}

      _ok ->
        :ok
    end
  end

  defp ensure_payload_object(action, message) do
    case message[action] do
      payload when is_map(payload) ->
        :ok

      _other ->
        {:error,
         Error.new(:validation, "INVALID_ACTION",
           "Payload for action '#{action}' must be an object"
         )}
    end
  end

  @spec check_message_version(module(), map()) :: :ok | {:error, Error.t()}
  defp check_message_version(adapter, message) do
    version = adapter.version()
    compatible = adapter.compatible_catalog_versions()

    case message do
      %{"version" => raw_version} when is_binary(raw_version) or is_atom(raw_version) ->
        canonical = SemVer.to_canonical(raw_version)

        if canonical in compatible do
          :ok
        else
          expected = expected_versions_text(compatible)
          {:error, version_mismatch_error(version, "Input should be #{expected}")}
        end

      %{"version" => _non_string} ->
        # The registry already type-checks `version`; defensive here.
        expected = expected_versions_text(compatible)
        {:error, version_mismatch_error(version, "Input should be #{expected}")}

      _missing ->
        {:error,
         version_mismatch_error(version, "version: 'version' is a required property")}
    end
  end

  defp version_mismatch_error(version, reason) do
    Error.new(:validation, "VERSION_MISMATCH", "Invalid #{version} message: #{reason}")
  end

  defp expected_versions_text(compatible) do
    sorted = compatible |> Enum.sort() |> Enum.map(&"v#{&1}")

    if length(sorted) == 1 do
      "'#{hd(sorted)}'"
    else
      "one of #{inspect(sorted)}"
    end
  end

  @spec validate_message_schema(module(), String.t(), map(), opts()) ::
          :ok | {:error, Error.t()}
  defp validate_message_schema(adapter, action, prepared, opts) do
    version = adapter.document_version()
    envelope = Source.document(version, :agent_to_renderer)
    common_types = Source.document(version, :common_types)
    catalog = Keyword.get(opts, :catalog) || Source.catalog(version, :basic)

    case message_def(envelope, action) do
      nil ->
        {:error,
         Error.new(
           :validation,
           "INVALID_ACTION",
           "Unknown message action '#{action}' for version #{version}"
         )}

      def ->
        registry = %{
          "common_types.json" => common_types,
          "catalog.json" => catalog
        }

        case Schema.validate(prepared, def, registry: registry, root: envelope) do
          :ok ->
            :ok

          {:error, details} ->
            summary = Enum.map_join(details, "; ", &summary_line/1)

            {:error,
             Error.new(:validation, "SCHEMA_VALIDATION_FAILED",
               "Invalid #{adapter.version()} message: #{summary}",
               details: details
             )}
        end
    end
  end

  defp summary_line(%Detail{path: ""} = detail), do: detail.message
  defp summary_line(%Detail{} = detail), do: "#{detail.path}: #{detail.message}"

  @doc false
  @spec message_def(map(), String.t()) :: map() | nil
  def message_def(envelope, action) when is_map(envelope) do
    defs = envelope["$defs"] || %{}
    Map.get(defs, def_name(action))
  end

  defp def_name("createSurface"), do: "CreateSurfaceMessage"
  defp def_name("updateComponents"), do: "UpdateComponentsMessage"
  defp def_name("updateDataModel"), do: "UpdateDataModelMessage"
  defp def_name("deleteSurface"), do: "DeleteSurfaceMessage"
  defp def_name("callRendererFunction"), do: "CallRendererFunctionMessage"
  defp def_name("agentFunctionResponse"), do: "AgentFunctionResponseMessage"
  defp def_name(_other), do: nil

  # ------------------------------------------------------------- behaviour --

  @doc """
  The version adapter behaviour. All callbacks are pure.
  """
  defmacro __using__(_opts) do
    quote do
      @behaviour A2UICore.Message.Adapter
    end
  end

  @callback version() :: String.t()
  @callback document_version() :: String.t()
  @callback compatible_catalog_versions() :: MapSet.t(String.t())
  @callback valid_actions() :: [String.t()]
  @callback prepare_message(map()) :: map()
  @callback extract_operations(action :: String.t(), message :: map()) :: [Operation.t()]
end
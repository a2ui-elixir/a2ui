defmodule A2UIConformance.Dispatcher do
  @moduledoc false

  # Maps each conformance case to the handler that runs it. The harness
  # uses this table to:
  #
  #   * dispatch actions that have a handler to their handler module, and
  #   * skip the rest with a reason derived from the case (skip reasons
  #     are computed, so they cannot rot).
  #
  # Dispatch keys on `{scope, action}` (see `A2UIConformance.Case`):
  # the same action name means different things in different suite
  # families, so a core handler must never pick up an extension case.
  #
  # Handlers implement `A2UIConformance.Handler`.

  alias A2UIConformance.Case

  # -- core/: the protocol engine ---------------------------------------------
  @core_areas %{
    "agent_to_renderer_schema" => "schema documents",
    "common_types_schema" => "schema documents",
    "validate_common_type" => "schema documents",
    "data_model" => "data model",
    "resolve_path" => "data model",
    "from_json" => "catalogs",
    "catalog_schema" => "catalogs",
    "evaluate_function" => "functions",
    "parse_expression_template" => "expressions",
    "validate" => "message processing",
    "process_messages" => "message processing",
    "get_renderer_capabilities" => "capabilities",
    "get_client_capabilities" => "capabilities",
    "get_renderer_data_model" => "capabilities",
    "get_client_data_model" => "capabilities",
    "select_catalog" => "catalog selection",
    "dispatch_action" => "actions",
    "resolve_nodes" => "node resolution",
    "accessibility_check" => "accessibility",
    "handle_rpc" => "function RPC"
  }

  # `resolve_nodes` is only meaningful in its own suite (reference
  # harness L619); anywhere else it is an unknown action.
  @node_resolution_suite "core/node_resolution.yaml"

  # -- agent/: the agent SDK ---------------------------------------------------
  @agent_actions ~w(
    compile decompile create_format create_processor generate_prompt
    generate_prompt_snippet parse_full parse_response parse_chunk
    process_chunk unwrap wrap fix_payload has_parts load_catalog
    provide_catalog transform_catalog prune resolve_catalogs skill_set
    from_format core_syntax from_catalog verify_cuttable_keys select_catalog
  )

  @agent_area "agent SDK"

  # Agent suite families outside the blueprint direct_json SDK.
  @optional_agent_scopes %{
    "agent/express" => "Express inference format",
    "agent/legacy" => "legacy agent SDK"
  }

  # -- extensions/: transports and framework integrations ---------------------------
  @extension_areas %{
    "extensions/a2a" => "A2A transport",
    "extensions/adk" => "ADK integration"
  }

  @extension_actions ~w(
    create_a2ui_part is_a2ui_part try_activate try_activate_extension
    get_extension handle_rpc select_newest convert_event execute_tool
    data_model resolve_path
  )

  # Handlers, keyed by {scope, action}.
  @handlers %{
    # schema documents and common types
    {"core", "agent_to_renderer_schema"} => A2UIConformance.Handlers.SchemaDocument,
    {"core", "common_types_schema"} => A2UIConformance.Handlers.SchemaDocument,
    {"core", "validate_common_type"} => A2UIConformance.Handlers.ValidateCommonType,
    # state and data model
    {"core", "data_model"} => A2UIConformance.Handlers.DataModel,
    {"core", "resolve_path"} => A2UIConformance.Handlers.ResolvePath,
    # catalogs, functions, expressions
    {"core", "from_json"} => A2UIConformance.Handlers.FromJson,
    {"core", "catalog_schema"} => A2UIConformance.Handlers.CatalogSchema,
    {"core", "evaluate_function"} => A2UIConformance.Handlers.EvaluateFunction,
    {"core", "parse_expression_template"} => A2UIConformance.Handlers.ParseExpressionTemplate,
    # message processing, capabilities, selection, actions
    {"core", "validate"} => A2UIConformance.Handlers.Validate,
    {"core", "process_messages"} => A2UIConformance.Handlers.ProcessMessages,
    {"core", "get_renderer_capabilities"} => A2UIConformance.Handlers.Capabilities,
    {"core", "get_client_capabilities"} => A2UIConformance.Handlers.Capabilities,
    {"core", "get_renderer_data_model"} => A2UIConformance.Handlers.RendererDataModel,
    {"core", "get_client_data_model"} => A2UIConformance.Handlers.RendererDataModel,
    {"core", "select_catalog"} => A2UIConformance.Handlers.SelectCatalog,
    {"core", "dispatch_action"} => A2UIConformance.Handlers.DispatchAction,
    # node resolution and accessibility
    {"core", "resolve_nodes"} => A2UIConformance.Handlers.ResolveNodes,
    {"core", "accessibility_check"} => A2UIConformance.Handlers.AccessibilityCheck,
    # function RPC
    {"core", "handle_rpc"} => A2UIConformance.Handlers.HandleRpc
  }

  @type resolution ::
          {:ok, module()}
          | {:unimplemented, String.t()}
          | {:optional, String.t()}
          | :unknown

  @doc """
  Resolves a case to `{:ok, handler}`, `{:unimplemented, area}` (a known
  action without a handler), `{:optional, label}` (an optional family),
  or `:unknown` (an action this scope has no vocabulary for — the
  harness fails those rather than skipping, per the upstream README).
  """
  @spec resolve(Case.t()) :: resolution()
  def resolve(%Case{scope: "core", action: "resolve_nodes", suite: suite})
      when suite != @node_resolution_suite,
      do: :unknown

  def resolve(%Case{scope: scope, action: action} = case) when is_binary(action) do
    case Map.fetch(@handlers, {scope, action}) do
      {:ok, module} -> {:ok, module}
      :error -> without_handler(case)
    end
  end

  def resolve(%Case{}), do: :unknown

  defp without_handler(%Case{scope: "core", action: action}) do
    case Map.fetch(@core_areas, action) do
      {:ok, area} -> {:unimplemented, area}
      :error -> :unknown
    end
  end

  defp without_handler(%Case{scope: "agent" <> _ = scope, action: action}) do
    cond do
      action not in @agent_actions ->
        :unknown

      Map.has_key?(@optional_agent_scopes, scope) ->
        {:optional, @optional_agent_scopes[scope]}

      true ->
        {:unimplemented, @agent_area}
    end
  end

  defp without_handler(%Case{scope: "extensions/" <> _ = scope, action: action}) do
    with true <- action in @extension_actions,
         {:ok, area} <- Map.fetch(@extension_areas, scope) do
      {:unimplemented, area}
    else
      _ -> :unknown
    end
  end

  defp without_handler(%Case{}), do: :unknown

  @doc """
  The implemented `{scope, action}` pairs, for reporting.
  """
  @spec implemented() :: [{String.t(), String.t()}]
  def implemented, do: @handlers |> Map.keys() |> Enum.sort()
end

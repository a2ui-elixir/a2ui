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
    "to_json" => "catalogs",
    "round_trip" => "catalogs",
    "validation_schema" => "catalogs",
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
    build expand transform_to_inference_catalog transform_to_inference
  )

  @agent_area "agent SDK"

  # Agent suite families this library does not implement.
  @optional_agent_scopes %{
    "agent/legacy" => "legacy agent SDK"
  }

  # -- extensions/: transports and framework integrations ---------------------------
  @extension_areas %{
    "extensions/a2a" => "A2A transport"
  }

  # Integrations with another SDK's runtime, which this library does not
  # have.
  @optional_extension_scopes %{
    "extensions/adk" => "ADK integration (Google's Agent Development Kit)"
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
    {"core", "to_json"} => A2UIConformance.Handlers.CatalogDocument,
    {"core", "round_trip"} => A2UIConformance.Handlers.CatalogDocument,
    {"core", "validation_schema"} => A2UIConformance.Handlers.CatalogDocument,
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
    {"core", "handle_rpc"} => A2UIConformance.Handlers.HandleRpc,
    # agent SDK: catalogs
    {"agent", "provide_catalog"} => A2UIConformance.Handlers.AgentCatalogs,
    {"agent", "transform_catalog"} => A2UIConformance.Handlers.AgentCatalogs,
    {"agent", "resolve_catalogs"} => A2UIConformance.Handlers.AgentCatalogs,
    # agent SDK: inference formats
    {"agent", "compile"} => A2UIConformance.Handlers.AgentFormats,
    {"agent", "decompile"} => A2UIConformance.Handlers.AgentFormats,
    {"agent", "parse_response"} => A2UIConformance.Handlers.AgentFormats,
    {"agent", "create_format"} => A2UIConformance.Handlers.AgentFormats,
    {"agent", "create_processor"} => A2UIConformance.Handlers.AgentFormats,
    {"agent/direct_json", "compile"} => A2UIConformance.Handlers.AgentFormats,
    {"agent/direct_json", "decompile"} => A2UIConformance.Handlers.AgentFormats,
    {"agent/direct_json", "generate_prompt_snippet"} => A2UIConformance.Handlers.AgentFormats,
    {"agent/direct_json", "unwrap"} => A2UIConformance.Handlers.AgentFormats,
    {"agent/direct_json", "wrap"} => A2UIConformance.Handlers.AgentFormats,
    {"agent/direct_json", "parse_response"} => A2UIConformance.Handlers.AgentFormats,
    {"agent/direct_json", "parse_chunk"} => A2UIConformance.Handlers.AgentFormats,
    {"agent/express", "compile"} => A2UIConformance.Handlers.AgentFormats,
    {"agent/express", "decompile"} => A2UIConformance.Handlers.AgentFormats,
    {"agent/express", "generate_prompt_snippet"} => A2UIConformance.Handlers.AgentFormats,
    {"agent/express", "unwrap"} => A2UIConformance.Handlers.AgentFormats,
    {"agent/express", "wrap"} => A2UIConformance.Handlers.AgentFormats,
    {"agent/express", "parse_response"} => A2UIConformance.Handlers.AgentFormats,
    # agent SDK: skills
    {"agent", "from_format"} => A2UIConformance.Handlers.Skills,
    {"agent", "core_syntax"} => A2UIConformance.Handlers.Skills,
    {"agent", "from_catalog"} => A2UIConformance.Handlers.Skills,
    {"agent", "skill_set"} => A2UIConformance.Handlers.Skills,
    # agent SDK: builder and macros
    {"agent/builder", "build"} => A2UIConformance.Handlers.Builder,
    {"agent/macros", "expand"} => A2UIConformance.Handlers.Macros,
    {"agent/macros", "transform_catalog"} => A2UIConformance.Handlers.Macros,
    {"agent/macros", "transform_to_inference_catalog"} => A2UIConformance.Handlers.Macros,
    {"agent/macros", "transform_to_inference"} => A2UIConformance.Handlers.Macros,
    # A2A extension
    {"extensions/a2a", "create_a2ui_part"} => A2UIConformance.Handlers.A2A,
    {"extensions/a2a", "is_a2ui_part"} => A2UIConformance.Handlers.A2A,
    {"extensions/a2a", "try_activate_extension"} => A2UIConformance.Handlers.A2A,
    {"extensions/a2a", "get_extension"} => A2UIConformance.Handlers.A2A,
    {"extensions/a2a", "try_activate"} => A2UIConformance.Handlers.A2A,
    {"extensions/a2a", "select_newest"} => A2UIConformance.Handlers.A2A,
    {"extensions/a2a", "handle_rpc"} => A2UIConformance.Handlers.A2A
  }

  # Inference formats this library does not implement, which a shared
  # agent suite names in `args.format` or `args.format_override`.
  @optional_formats %{
    "elemental" => "Elemental inference format",
    "atom" => "Atom inference format"
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
    with nil <- optional_format(case),
         {:ok, module} <- Map.fetch(@handlers, {scope, action}) do
      {:ok, module}
    else
      {:optional, _label} = optional -> optional
      :error -> without_handler(case)
    end
  end

  def resolve(%Case{}), do: :unknown

  defp optional_format(%Case{scope: "agent" <> _, action: action, raw: %{"args" => %{} = args}}) do
    if action in @agent_actions do
      [args["format"], args["format_override"]]
      |> Enum.find_value(&Map.get(@optional_formats, &1))
      |> case do
        nil -> nil
        label -> {:optional, label}
      end
    end
  end

  defp optional_format(%Case{}), do: nil

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
    cond do
      action not in @extension_actions ->
        :unknown

      Map.has_key?(@optional_extension_scopes, scope) ->
        {:optional, @optional_extension_scopes[scope]}

      Map.has_key?(@extension_areas, scope) ->
        {:unimplemented, @extension_areas[scope]}

      true ->
        :unknown
    end
  end

  defp without_handler(%Case{}), do: :unknown

  @doc """
  The implemented `{scope, action}` pairs, for reporting.
  """
  @spec implemented() :: [{String.t(), String.t()}]
  def implemented, do: @handlers |> Map.keys() |> Enum.sort()
end

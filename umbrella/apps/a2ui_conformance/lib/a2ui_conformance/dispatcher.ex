defmodule A2UIConformance.Dispatcher do
  @moduledoc false

  # Maps each conformance case to the handler that runs it, or to the
  # build phase that will implement it (see PLAN.md / TODO.md). The
  # harness uses this table to:
  #
  #   * dispatch implemented actions to their handler module, and
  #   * skip unimplemented actions with a phase-tagged reason (skip
  #     reasons are derived from the case, so they cannot rot).
  #
  # Dispatch keys on `{scope, action}` (see `A2UIConformance.Case`):
  # the same action name means different things in different suite
  # families, so a core handler must never pick up an extension case.
  #
  # Handlers implement `A2UIConformance.Handler`.

  alias A2UIConformance.Case

  # -- core/: the protocol engine, phases 2-7 -----------------------------------
  @core_phases %{
    # Phase 2: wire messages & schemas
    "agent_to_renderer_schema" => 2,
    "common_types_schema" => 2,
    "validate_common_type" => 2,
    # Phase 3: state & data model
    "data_model" => 3,
    "resolve_path" => 3,
    # Phase 4: catalog, functions, expressions
    "from_json" => 4,
    "catalog_schema" => 4,
    "evaluate_function" => 4,
    "parse_expression_template" => 4,
    # Phase 5: processor
    "validate" => 5,
    "process_messages" => 5,
    "get_renderer_capabilities" => 5,
    "get_client_capabilities" => 5,
    "get_renderer_data_model" => 5,
    "get_client_data_model" => 5,
    "select_catalog" => 5,
    "dispatch_action" => 5,
    # Phase 6: node resolution & accessibility
    "resolve_nodes" => 6,
    "accessibility_check" => 6,
    # Phase 7: RPC
    "handle_rpc" => 7
  }

  # `resolve_nodes` is only meaningful in its own suite (reference
  # harness L619); anywhere else it is an unknown action.
  @node_resolution_suite "core/node_resolution.yaml"

  # -- agent/: the agent SDK, phase 10 -------------------------------------------
  @agent_actions ~w(
    compile decompile create_format create_processor generate_prompt
    generate_prompt_snippet parse_full parse_response parse_chunk
    process_chunk unwrap wrap fix_payload has_parts load_catalog
    provide_catalog transform_catalog prune resolve_catalogs skill_set
    from_format core_syntax from_catalog verify_cuttable_keys select_catalog
  )

  # Agent suite families that are optional follow-ups after the blueprint
  # direct_json SDK (user decision, TODO.md M10).
  @optional_agent_scopes %{
    "agent/express" => "Express inference format",
    "agent/legacy" => "legacy agent SDK"
  }

  # -- extensions/: transports and framework integrations ---------------------------
  @extension_phases %{
    "extensions/a2a" => 9,
    "extensions/adk" => 10
  }

  @extension_actions ~w(
    create_a2ui_part is_a2ui_part try_activate try_activate_extension
    get_extension handle_rpc select_newest convert_event execute_tool
    data_model resolve_path
  )

  # Implemented handlers, keyed by {scope, action}. Filled in as phases land.
  @handlers %{
    # Phase 2
    {"core", "agent_to_renderer_schema"} => A2UIConformance.Handlers.SchemaDocument,
    {"core", "common_types_schema"} => A2UIConformance.Handlers.SchemaDocument,
    {"core", "validate_common_type"} => A2UIConformance.Handlers.ValidateCommonType,
    # Phase 3
    {"core", "data_model"} => A2UIConformance.Handlers.DataModel,
    {"core", "resolve_path"} => A2UIConformance.Handlers.ResolvePath
  }

  @type resolution ::
          {:ok, module()}
          | {:pending, pos_integer()}
          | {:optional, pos_integer(), String.t()}
          | :unknown

  @doc """
  Resolves a case to `{:ok, handler}`, `{:pending, phase}`,
  `{:optional, phase, label}` (an optional follow-up milestone), or
  `:unknown` (an action this scope has no vocabulary for — the harness
  fails those rather than skipping, per the upstream README).
  """
  @spec resolve(Case.t()) :: resolution()
  def resolve(%Case{scope: scope, action: action} = case) when is_binary(action) do
    case Map.fetch(@handlers, {scope, action}) do
      {:ok, module} -> {:ok, module}
      :error -> pending(case)
    end
  end

  def resolve(%Case{}), do: :unknown

  defp pending(%Case{scope: "core", action: "resolve_nodes", suite: suite})
       when suite != @node_resolution_suite,
       do: :unknown

  defp pending(%Case{scope: "core", action: action}) do
    case Map.fetch(@core_phases, action) do
      {:ok, phase} -> {:pending, phase}
      :error -> :unknown
    end
  end

  defp pending(%Case{scope: "agent" <> _ = scope, action: action}) do
    cond do
      action not in @agent_actions ->
        :unknown

      Map.has_key?(@optional_agent_scopes, scope) ->
        {:optional, 10, @optional_agent_scopes[scope]}

      true ->
        {:pending, 10}
    end
  end

  defp pending(%Case{scope: "extensions/" <> _ = scope, action: action}) do
    with true <- action in @extension_actions,
         {:ok, phase} <- Map.fetch(@extension_phases, scope) do
      {:pending, phase}
    else
      _ -> :unknown
    end
  end

  defp pending(%Case{}), do: :unknown

  @doc """
  The implemented `{scope, action}` pairs, for reporting.
  """
  @spec implemented() :: [{String.t(), String.t()}]
  def implemented, do: @handlers |> Map.keys() |> Enum.sort()
end

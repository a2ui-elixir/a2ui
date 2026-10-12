defmodule A2UIConformance.Dispatcher do
  @moduledoc false

  # Maps each conformance `action` to the build phase that implements it
  # (see PLAN.md). The harness uses this table to:
  #
  #   * dispatch implemented actions to their handler module, and
  #   * skip unimplemented actions with a phase-tagged reason
  #     (skip reasons are derived from the case, so they cannot rot).
  #
  # An action moves from `:pending {phase}` to `{:handler, module}` as
  # its phase lands. Handlers live in `A2UIConformance.Handlers.*`
  # and implement `run/2` (case, context) — returning `:ok`,
  # `{:error, error}` (an `A2UICore.Error` — the matcher asserts it),
  # or raising.

  @pending [
    # -- Phase 2: wire messages & schemas ------------------------------------
    {"agent_to_renderer_schema", 2},
    {"common_types_schema", 2},
    {"validate_common_type", 2},
    # -- Phase 3: state & data model ------------------------------------------
    {"data_model", 3},
    {"resolve_path", 3},
    # -- Phase 4: catalog, functions, expressions ------------------------------
    {"from_json", 4},
    {"catalog_schema", 4},
    {"evaluate_function", 4},
    {"parse_expression_template", 4},
    # -- Phase 5: processor ----------------------------------------------------
    {"validate", 5},
    {"process_messages", 5},
    {"get_renderer_capabilities", 5},
    {"get_client_capabilities", 5},
    {"get_renderer_data_model", 5},
    {"get_client_data_model", 5},
    {"select_catalog", 5},
    {"dispatch_action", 5},
    # -- Phase 6: node resolution -----------------------------------------------
    {"resolve_nodes", 6},
    {"accessibility_check", 6},
    # -- Phase 7: RPC ------------------------------------------------------------
    {"handle_rpc", 7},
    # -- Phase 8: phoenix renderer -------------------------------------------------
    {"render", 8},
    # -- Phase 10: agent SDK -------------------------------------------------------
    {"compile", 10},
    {"decompile", 10},
    {"create_format", 10},
    {"create_processor", 10},
    {"generate_prompt", 10},
    {"generate_prompt_snippet", 10},
    {"parse_full", 10},
    {"parse_response", 10},
    {"parse_chunk", 10},
    {"process_chunk", 10},
    {"unwrap", 10},
    {"wrap", 10},
    {"fix_payload", 10},
    {"has_parts", 10},
    {"load_catalog", 10},
    {"provide_catalog", 10},
    {"transform_catalog", 10},
    {"prune", 10},
    {"resolve_catalogs", 10},
    {"skill_set", 10},
    {"from_format", 10},
    {"core_syntax", 10},
    {"from_catalog", 10},
    {"verify_cuttable_keys", 10},
    # -- Phase 10 extensions (a2a/adk) --------------------------------------------
    {"create_a2ui_part", 10},
    {"is_a2ui_part", 10},
    {"try_activate", 10},
    {"try_activate_extension", 10},
    {"get_extension", 10},
    {"convert_event", 10},
    {"execute_tool", 10},
    {"select_newest", 10}
  ]

  @doc """
  Returns `{:ok, module}` when the action has a handler, or
  `{:pending, phase}` with the phase that will implement it.
  Unknown actions return `:unknown` (the harness fails those rather
  than skipping, per the upstream README).
  """
  @spec resolve(String.t()) :: {:ok, module()} | {:pending, pos_integer()} | :unknown
  def resolve(action) when is_binary(action) do
    case Map.fetch(handlers(), action) do
      {:ok, module} ->
        {:ok, module}

      :error ->
        case List.keyfind(@pending, action, 0) do
          {^action, phase} -> {:pending, phase}
          nil -> :unknown
        end
    end
  end

  @spec handler_entries() :: [{String.t(), module()}]
  defp handler_entries do
    [
      # Filled in as phases land, e.g.:
      # {"data_model", A2UIConformance.Handlers.DataModel}
    ]
  end

  @spec handlers() :: %{optional(String.t()) => module()}
  defp handlers, do: Map.new(handler_entries())

  @doc """
  All actions the schema vocabulary knows, for validation tooling.
  """
  @spec known_actions() :: [String.t()]
  def known_actions, do: Enum.map(@pending, &elem(&1, 0)) |> Enum.sort()
end

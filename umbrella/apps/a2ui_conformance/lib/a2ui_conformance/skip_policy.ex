defmodule A2UIConformance.SkipPolicy do
  @moduledoc false

  # Derives a skip decision for a case. Skip reasons are *computed* from
  # the case and the dispatcher state, so they cannot silently rot:
  #
  #   1. A protocol version outside the supported set, or a suite written
  #      for v0.8 -> version skip (v0.8 is out of scope by design).
  #   2. Action without a handler -> skip, with the reason the
  #      dispatcher reports (unimplemented area or optional family).
  #   3. Explicit per-case skips (case-level exceptions) — a named list
  #      validated against the real case corpus; an entry that matches no
  #      case is itself a test failure.
  #
  # Supported versions match `A2UICore.Version.supported/0`.

  alias A2UIConformance.{Case, Dispatcher}

  # {{"suite (relative path)", "case name"}, "reason"} — remove an entry
  # once the underlying case passes.
  @explicit_case_skips [
    {{"extensions/a2a/a2a_integration.yaml", "test_handler_replaces_smart_quotes"},
     "protocol v0.8 payload and catalog (beginRendering; out of scope)"}
  ]

  # Legacy cases whose rules the blueprint suites replaced on purpose,
  # keyed by suite and case name (`:all` for a whole suite, `{:action,
  # name}` for every case of an action), with the rule that replaced
  # them. The TypeScript SDK's harness skips the same cases. Every entry
  # must match a case.
  @superseded %{
    {"agent/legacy/streaming_parser.yaml", :all} =>
      "replaced by agent/direct_json/response_streaming.yaml, whose streaming rules " <>
        "this library follows",
    {"agent/legacy/inference_format.yaml", {:action, "generate_prompt"}} =>
      "replaced by agent/direct_json/prompt_generator.yaml: the generator writes the " <>
        "A2UI part of the prompt and leaves the rest to the agent",
    {"agent/legacy/inference_format.yaml", "test_agent_v1_0_direct_json_envelope_parsing"} =>
      "replaced by agent/direct_json/response_streaming.yaml: text outside a block is " <>
        "emitted without its trailing whitespace",
    {"agent/legacy/parser.yaml", "test_parse_empty_response"} =>
      "replaced by agent/direct_json/response_parser.yaml: an empty response has no parts",
    {"agent/legacy/parser.yaml", "test_parse_response_only_text_no_tags"} =>
      "replaced by agent/direct_json/response_parser.yaml: a response without tags is " <>
        "one text part",
    {"agent/legacy/parser.yaml", "test_parse_response_empty_tags"} =>
      "replaced by the blueprint parser, which reports an empty block when it compiles " <>
        "it ('The direct JSON block is empty.'), not when it splits the response"
  }

  @superseded_resolution "replaced by agent/catalog_resolution.yaml, which activates " <>
                           "every catalog in common and adds inline catalogs alongside them"

  @superseded_resolution_cases ~w(
    test_select_catalog_default test_select_catalog_no_match test_select_catalog_inline
    test_select_catalog_multiple_inline test_select_catalog_no_match_with_inline
    test_select_catalog_inline_not_accepted
  )

  defp superseded do
    for name <- @superseded_resolution_cases,
        into: @superseded,
        do: {{"agent/legacy/inference_format.yaml", name}, @superseded_resolution}
  end

  @doc """
  Returns `nil` (run the case) or `{:skip, reason}`.
  """
  @spec skip_for(Case.t()) :: {:skip, String.t()} | nil
  def skip_for(%Case{} = case) do
    version_skip(case) || superseded_skip(case) || dispatcher_skip(case) || explicit_skip(case)
  end

  defp superseded_skip(%Case{suite: suite, name: name, action: action}) do
    entries = superseded()

    case entries[{suite, name}] || entries[{suite, {:action, action}}] || entries[{suite, :all}] do
      nil -> nil
      reason -> {:skip, "superseded: " <> reason}
    end
  end

  defp version_skip(%Case{protocol_version: version, suite: suite} = case) do
    cond do
      String.ends_with?(suite, "_v0_8.yaml") ->
        {:skip, "protocol v0.8 suite (out of scope)"}

      v08_agent_catalog?(case) ->
        {:skip, "protocol v0.8 catalog (out of scope)"}

      version in A2UICore.Version.supported() ->
        nil

      true ->
        {:skip, "unsupported protocol version #{inspect(version)}"}
    end
  end

  # Agent cases name their catalogs by file in `args`; the reference
  # harness runs them under whatever version the file states.
  defp v08_agent_catalog?(%Case{scope: "agent" <> _, raw: %{"args" => %{} = args}}) do
    [args["catalog"] | List.wrap(args["catalogs"])]
    |> Enum.map(fn
      %{"catalog" => path} -> path
      path -> path
    end)
    |> Enum.any?(&(is_binary(&1) and String.contains?(&1, ["_v0_8", "_v08"])))
  end

  defp v08_agent_catalog?(%Case{}), do: false

  defp dispatcher_skip(%Case{action: nil}),
    do: {:skip, "case has no action"}

  defp dispatcher_skip(%Case{action: action} = case) do
    case Dispatcher.resolve(case) do
      {:ok, _module} -> nil
      {:unimplemented, area} -> {:skip, "no handler for action '#{action}' (#{area})"}
      {:optional, label} -> {:skip, "optional family without a handler: #{label}"}
      :unknown -> nil
    end
  end

  defp explicit_skip(%Case{suite: suite, name: name}) do
    case List.keyfind(@explicit_case_skips, {suite, name}, 0) do
      {{^suite, ^name}, reason} -> {:skip, reason}
      nil -> nil
    end
  end

  @doc """
  Validates that every explicit case-skip entry matches a real case.
  Called from the harness boot test; a stale entry fails the suite
  (the "skip lists must not rot" rule).
  """
  @spec validate_explicit_skips!([Case.t()]) :: :ok
  def validate_explicit_skips!(cases) do
    existing = MapSet.new(cases, &{&1.suite, &1.name})

    covered =
      MapSet.union(
        existing,
        MapSet.new(cases, &{&1.suite, :all})
        |> MapSet.union(MapSet.new(cases, &{&1.suite, {:action, &1.action}}))
      )

    stale =
      (Enum.map(@explicit_case_skips, &elem(&1, 0)) ++ Map.keys(superseded()))
      |> Enum.reject(&MapSet.member?(covered, &1))

    if stale != [] do
      raise ArgumentError,
            "explicit case skips that match no real case (stale skip entries): " <>
              inspect(stale, pretty: true)
    end

    :ok
  end
end

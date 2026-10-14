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

  @doc """
  Returns `nil` (run the case) or `{:skip, reason}`.
  """
  @spec skip_for(Case.t()) :: {:skip, String.t()} | nil
  def skip_for(%Case{} = case) do
    version_skip(case) || dispatcher_skip(case) || explicit_skip(case)
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

    stale =
      @explicit_case_skips
      |> Enum.map(&elem(&1, 0))
      |> Enum.reject(&MapSet.member?(existing, &1))

    if stale != [] do
      raise ArgumentError,
            "explicit case skips that match no real case (stale skip entries): " <>
              inspect(stale, pretty: true)
    end

    :ok
  end
end

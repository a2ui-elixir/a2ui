defmodule A2UIConformance.SkipPolicy do
  @moduledoc false

  # Derives a skip decision for a case. Skip reasons are *computed* from
  # the case and the dispatcher state, so they cannot silently rot:
  #
  #   1. `protocolVersion` outside the supported set -> version skip.
  #   2. Action without a handler yet -> phase-tagged skip.
  #   3. Explicit per-case skips (case-level exceptions) — these are a
  #      named list that is validated against the real case corpus; an
  #      entry that matches no case is itself a test failure.
  #
  # Supported versions match `A2UICore.Version.supported/0`.

  alias A2UIConformance.{Case, Dispatcher}

  @explicit_case_skips [
    # {"suite (relative path)", "case name", "reason"} — validated on
    # boot; remove entries as their phases fix the underlying cases.
  ]

  @doc """
  Returns `nil` (run the case) or `{:skip, reason}`.
  """
  @spec skip_for(Case.t()) :: {:skip, String.t()} | nil
  def skip_for(%Case{} = case) do
    version_skip(case) || dispatcher_skip(case) || explicit_skip(case)
  end

  defp version_skip(%Case{protocol_version: nil}), do: nil

  defp version_skip(%Case{protocol_version: version}) do
    if A2UICore.Version.protocol_version?(version) and
         version in A2UICore.Version.supported() do
      nil
    else
      {:skip, "unsupported protocol version #{inspect(version)}"}
    end
  end

  defp dispatcher_skip(%Case{action: nil}),
    do: {:skip, "case has no action"}

  defp dispatcher_skip(%Case{action: action}) do
    case Dispatcher.resolve(action) do
      {:ok, _module} -> nil
      {:pending, phase} -> {:skip, "action '#{action}' lands in phase #{phase}"}
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

defmodule A2UIConformance.Handlers.ValidateCommonType do
  @moduledoc false

  # `validate_common_type` (reference harness L1194-1228): each step's
  # `value` is validated as the case's common-types `definition`. A step
  # with `expectError` must be rejected with a matching error; any other
  # step must be accepted and the validated value must reproduce `value`
  # exactly.

  @behaviour A2UIConformance.Handler

  alias A2UIConformance.{Case, Matchers}
  alias A2UICore.CommonTypes

  @impl true
  def run(%Case{protocol_version: version, raw: raw}, _context) do
    definition = raw["definition"]

    for {step, index} <- Enum.with_index(raw["steps"]) do
      value = step["value"]

      case {step["expectError"], CommonTypes.validate(value, definition, version)} do
        {nil, {:ok, validated}} ->
          Matchers.assert_strict_equal(
            value,
            validated,
            "step #{index}: round-trip of #{inspect(value)}"
          )

        {nil, {:error, error}} ->
          ExUnit.Assertions.flunk(
            "step #{index}: #{inspect(value)} rejected: #{Exception.message(error)}"
          )

        {expected, {:error, error}} ->
          Matchers.assert_error(expected, error)

        {_expected, {:ok, _validated}} ->
          ExUnit.Assertions.flunk("step #{index}: #{inspect(value)} accepted, expected an error")
      end
    end

    :ok
  end
end

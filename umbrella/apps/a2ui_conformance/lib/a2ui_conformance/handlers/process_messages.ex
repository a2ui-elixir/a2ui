defmodule A2UIConformance.Handlers.ProcessMessages do
  @moduledoc false

  # `process_messages` (reference harness L855-902): like `validate`, but
  # the processor only validates components when the case asks for it
  # (`strictMode` / `strict_mode` / `options.strict_mode`). A case holds
  # `messages` (or one `payload`) with a case-level `expectError` /
  # `expect`, or `steps` whose last step falls back to the case's.

  @behaviour A2UIConformance.Handler

  import ExUnit.Assertions

  alias A2UIConformance.{Case, CatalogFixtures, Matchers, SurfaceState}
  alias A2UIConformance.Handlers.Validate
  alias A2UICore.Processor
  alias A2UICore.Validation.Config

  @impl true
  def run(%Case{raw: raw} = test_case, _context) do
    {:ok, catalogs} = CatalogFixtures.for_case(test_case)
    validation = if strict?(raw), do: Config.strict()
    processor = Processor.new(catalogs, validation: validation)

    case case_messages(raw) do
      nil -> run_steps(processor, raw)
      messages -> run_messages(processor, messages, raw["expectError"], raw["expect"] || %{})
    end

    :ok
  end

  defp strict?(raw) do
    options = if is_map(raw["options"]), do: raw["options"], else: %{}

    truthy?(raw["strictMode"]) or truthy?(raw["strict_mode"]) or truthy?(options["strict_mode"])
  end

  defp case_messages(raw) do
    cond do
      truthy?(raw["messages"]) -> raw["messages"]
      Map.has_key?(raw, "payload") -> [raw["payload"]]
      true -> nil
    end
  end

  defp run_steps(processor, raw) do
    steps = List.wrap(raw["steps"])
    last = length(steps) - 1

    steps
    |> Enum.with_index()
    |> Enum.reduce(processor, fn {step, index}, processor ->
      run_step(processor, step, index == last, raw)
    end)
  end

  defp run_step(processor, step, last?, raw) do
    case Validate.step_messages(step) do
      nil ->
        processor

      messages ->
        expect_error = step["expectError"] || if(last?, do: raw["expectError"])
        expected = step["expect"] || if(last?, do: raw["expect"]) || %{}
        run_messages(processor, messages, expect_error, expected)
    end
  end

  defp run_messages(processor, messages, expect_error, expected) do
    case {Processor.process(processor, messages), expect_error} do
      {{:ok, processor, _effects}, nil} ->
        SurfaceState.assert_state(processor, expected)
        processor

      {{:error, error, _processor}, nil} ->
        flunk("unexpected error: #{Exception.message(error)}")

      {{:error, error, processor}, expected_error} ->
        Matchers.assert_error(expected_error, error)
        processor

      {{:ok, _processor, _effects}, expected_error} ->
        flunk(
          "expected an error matching #{inspect(expected_error)}, but the messages were accepted"
        )
    end
  end

  defp truthy?(value), do: value not in [nil, false, "", [], %{}, 0]
end

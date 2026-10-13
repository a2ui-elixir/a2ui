defmodule A2UIConformance.Handlers.Validate do
  @moduledoc false

  # `validate` (reference harness L812-852): messages go through a
  # processor with the strict validation configuration. A case is a
  # list of `steps` (or is itself the only step); each step carries
  # `messages` / `payload` / `message` and either an `expectError` or an
  # `expect` of surface state. The case-level `expectError` / `expect`
  # applies to the last step.
  #
  # An expected error is also satisfied by the first error a surface
  # raises while its components are resolved — the harness subscribes to
  # the surfaces' error streams and raises the first one.

  @behaviour A2UIConformance.Handler

  import ExUnit.Assertions

  alias A2UIConformance.{Case, CatalogFixtures, Matchers, SurfaceState}
  alias A2UICore.Error
  alias A2UICore.Processor
  alias A2UICore.Validation.Config

  @impl true
  def run(%Case{raw: raw} = test_case, _context) do
    {:ok, catalogs} = CatalogFixtures.for_case(test_case)
    processor = Processor.new(catalogs, validation: Config.strict())

    steps = if is_list(raw["steps"]) and raw["steps"] != [], do: raw["steps"], else: [raw]
    last = length(steps) - 1

    _processor =
      steps
      |> Enum.with_index()
      |> Enum.reduce(processor, fn {step, index}, processor ->
        run_step(processor, step, index == last, raw)
      end)

    :ok
  end

  defp run_step(processor, step, last?, raw) do
    case step_messages(step) do
      nil ->
        processor

      messages ->
        expect_error = step["expectError"] || if(last?, do: raw["expectError"])

        if expect_error,
          do: expect_failure(processor, messages, expect_error),
          else: expect_success(processor, messages, step, last?, raw)
    end
  end

  defp expect_failure(processor, messages, expected) do
    case Processor.process(processor, messages) do
      {:error, error, processor} ->
        Matchers.assert_error(expected, error)
        processor

      {:ok, processor, _effects} ->
        case SurfaceState.first_resolution_error(processor) do
          nil ->
            flunk(
              "expected an error matching #{inspect(expected)}, but the messages were accepted"
            )

          message ->
            Matchers.assert_error(expected, Error.new(:validation, "EXPRESSION_ERROR", message))
            processor
        end
    end
  end

  defp expect_success(processor, messages, step, last?, raw) do
    case Processor.process(processor, messages) do
      {:ok, processor, _effects} ->
        expected = present(step["expect"]) || if(last?, do: raw["expect"])
        if present(expected), do: SurfaceState.assert_state(processor, expected)
        processor

      {:error, error, _processor} ->
        flunk("unexpected error: #{Exception.message(error)}")
    end
  end

  @doc false
  @spec step_messages(map()) :: term() | nil
  def step_messages(step) do
    cond do
      present(step["messages"]) -> step["messages"]
      present(step["payload"]) -> step["payload"]
      Map.has_key?(step, "message") -> [step["message"]]
      true -> nil
    end
  end

  defp present(value) when value in [nil, false, "", [], %{}], do: nil
  defp present(value), do: value
end

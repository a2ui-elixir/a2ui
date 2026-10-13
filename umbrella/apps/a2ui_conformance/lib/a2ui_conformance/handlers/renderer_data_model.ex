defmodule A2UIConformance.Handlers.RendererDataModel do
  @moduledoc false

  # `get_renderer_data_model` / `get_client_data_model` (reference
  # harness L1347-1370): process the case's messages, then read the
  # renderer data model for `args.version` (else the case's protocol
  # version). `expect: null` means no data model; `expect.data` or the
  # whole `expect` is compared for equality.

  @behaviour A2UIConformance.Handler

  import ExUnit.Assertions

  alias A2UIConformance.{Case, CatalogFixtures, Matchers}
  alias A2UICore.Processor

  @impl true
  def run(%Case{raw: raw, protocol_version: protocol_version} = test_case, _context) do
    {:ok, catalogs} = CatalogFixtures.for_case(test_case)
    processor = Processor.new(catalogs)

    processor =
      Enum.reduce(batches(raw), processor, fn messages, processor ->
        case Processor.process(processor, messages) do
          {:ok, processor, _effects} -> processor
          {:error, error, _processor} -> flunk("unexpected error: #{Exception.message(error)}")
        end
      end)

    args = if is_map(raw["args"]), do: raw["args"], else: %{}
    version = args["version"] || protocol_version

    case Processor.renderer_data_model(processor, version) do
      {:ok, actual} -> assert_expected(raw, actual)
      {:error, error} -> flunk("unexpected error: #{Exception.message(error)}")
    end

    :ok
  end

  defp batches(raw) do
    case raw["steps"] do
      [_ | _] = steps ->
        for step <- steps,
            messages = step["messages"] || step["payload"],
            messages not in [nil, []],
            do: messages

      _no_steps ->
        cond do
          raw["messages"] not in [nil, []] -> [raw["messages"]]
          Map.has_key?(raw, "payload") -> [[raw["payload"]]]
          true -> []
        end
    end
  end

  defp assert_expected(raw, actual) do
    case Map.fetch(raw, "expect") do
      {:ok, nil} ->
        assert actual == nil, "expected no renderer data model, got #{inspect(actual)}"

      {:ok, %{"data" => data}} ->
        Matchers.assert_json_equal(data, actual, "renderer data model")

      {:ok, %{} = expected} ->
        Matchers.assert_json_equal(expected, actual, "renderer data model")

      _no_expectation ->
        :ok
    end
  end
end

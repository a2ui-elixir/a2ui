defmodule A2UIConformance.Handlers.Legacy do
  @moduledoc false

  # The cases of conformance/agent/legacy/ whose rules still hold for the
  # blueprint agent interface, run as the TypeScript SDK's harness runs
  # them (typescript/agents/a2ui_agent/tests/conformance/conformance.test.ts):
  #
  #   * parse_full — a direct JSON response split with the parser's
  #     `unwrap/1`, each block read with `A2UIAgent.PayloadFixer` (the
  #     legacy parser did not validate), or an Express response parsed by
  #     the Express parser; parts compare as text-and-payload pairs, text
  #     trimmed;
  #   * fix_payload — `A2UIAgent.PayloadFixer.parse_and_fix/1`;
  #   * has_parts — `has_format_content?/2` with `complete: true`;
  #   * select_catalog — v1.0 catalogs made from `supportedCatalogs`,
  #     resolved against `clientCapabilities`;
  #   * load_catalog — catalog files, as v0.9 when they state no version
  #     (the legacy SDK's default).
  #
  # Cases whose rules the blueprint suites replaced are skipped by
  # `A2UIConformance.SkipPolicy`, with the suite that replaced them.

  @behaviour A2UIConformance.Handler

  import ExUnit.Assertions

  alias A2UIAgent.{CatalogConfig, CatalogResolver, Express, PayloadFixer}
  alias A2UIAgent.DirectJson.Parser
  alias A2UIConformance.{Case, Matchers, Registry}
  alias A2UICore.Catalog

  @impl true
  def run(%Case{action: action, raw: raw}, _context) do
    run_action(action, raw)
    :ok
  end

  defp run_action("parse_full", raw), do: check_outcome(raw, parse_full(raw))

  defp run_action("fix_payload", raw) do
    case {raw["expectError"], PayloadFixer.parse_and_fix(raw["input"])} do
      {nil, {:ok, payload}} -> Matchers.assert_json_equal(raw["expect"], payload, "fixed payload")
      {nil, {:error, error}} -> flunk("the payload did not read: #{error.message}")
      {expected, result} -> Matchers.assert_error(expected, result)
    end
  end

  defp run_action("has_parts", raw),
    do: assert(Parser.has_format_content?(raw["input"], complete: true) == raw["expect"])

  defp run_action("select_catalog", raw), do: select_catalog(raw["args"] || %{}, raw)
  defp run_action("load_catalog", raw), do: load_catalog(raw)

  defp select_catalog(args, raw) do
    configs = Enum.map(args["supportedCatalogs"] || [], &catalog_config/1)
    capabilities = %{"v1.0" => args["clientCapabilities"] || %{}}
    options = [accepts_inline_catalogs: args["acceptsInlineCatalogs"] == true]
    assert {:ok, active} = CatalogResolver.resolve(configs, capabilities, options)
    assert_selected(active, raw["expect"] || %{}, raw["expectSelected"])
  end

  defp catalog_config(entry) do
    document = %{"catalogId" => entry["catalogId"], "components" => entry["components"] || %{}}
    CatalogConfig.new(Catalog.from_json!(document, protocol_version: "v1.0"))
  end

  defp assert_selected([first | _] = active, expected, selected) do
    selected = selected || expected["catalogId"]
    if selected, do: assert(first.catalog_id == selected)

    for {name, _schema} <- expected["components"] || %{},
        do: assert(Enum.any?(active, &Map.has_key?(&1.components, name)), "#{name} is not active")
  end

  defp load_catalog(raw) do
    configs = Enum.map(raw["catalogConfigs"] || [], &load_config/1)

    case raw["expect"] || %{} do
      %{"supportedCatalogIds" => ids} ->
        assert Enum.map(configs, & &1.transformed.catalog_id) == ids

      expected ->
        assert_catalog(hd(configs).transformed, expected)
    end
  end

  # The catalog has the expected id and components, and keeps a
  # component's `additionalProperties: false`.
  defp assert_catalog(catalog, expected) do
    assert catalog.catalog_id == expected["catalogId"]
    components = Catalog.to_json(catalog)["components"]

    for {name, schema} <- expected["components"] || %{} do
      assert Map.has_key?(components, name), "#{name} is not in the catalog"
      strict? = schema["additionalProperties"] == false
      assert not strict? or components[name]["additionalProperties"] == false
    end
  end

  defp load_config(%{"path" => relative}) do
    path = Path.join([Registry.reference_root(), "conformance", relative])

    options =
      if Map.has_key?(Jason.decode!(File.read!(path)), "protocolVersion"),
        do: [],
        else: [protocol_version: "v0.9"]

    {:ok, config} = CatalogConfig.from_path(path, options)
    config
  end

  # -- parse_full ---------------------------------------------------------------------

  defp parse_full(%{"format" => "express"} = raw) do
    version = get_in(raw, ["catalog", "protocolVersion"]) || "v1.0"
    catalog = Catalog.Basic.catalog(if version in ["v0.9", "0.9"], do: "v0.9.1", else: "v1.0")
    {:ok, parser} = Express.Parser.new([catalog])
    Express.Parser.parse_response(parser, raw["input"])
  end

  defp parse_full(raw) do
    raw["input"]
    |> Parser.unwrap()
    |> Enum.reduce_while({:ok, []}, fn
      {:text, text}, {:ok, parts} ->
        {:cont, {:ok, parts ++ [{:text, text}]}}

      {:a2ui_raw, block, _final?}, {:ok, parts} ->
        case PayloadFixer.parse_and_fix(block) do
          {:ok, payload} -> {:cont, {:ok, parts ++ [{:a2ui, payload}]}}
          {:error, _error} = error -> {:halt, error}
        end
    end)
  end

  defp check_outcome(raw, result) do
    case {raw["expectError"], result} do
      {nil, {:ok, parts}} ->
        actual = pairs(parts)
        expected = raw["expect"] || []
        assert length(actual) == length(expected), "parts: #{inspect(actual)}"

        for {got, want} <- Enum.zip(actual, expected) do
          assert String.trim(got["text"] || "") == String.trim(want["text"] || "")
          Matchers.assert_json_equal(want["a2ui"], got["a2ui"], "payload")
        end

      {nil, {:error, error}} ->
        flunk("the response did not parse: #{error.message}")

      {expected, result} ->
        Matchers.assert_error(expected, result)
    end
  end

  # Text before a payload goes with it, as the legacy parts did.
  defp pairs(parts) do
    {pairs, pending} =
      Enum.reduce(parts, {[], nil}, fn
        {:text, text}, {pairs, pending} -> {pairs, (pending || "") <> text}
        {:a2ui, payload}, {pairs, pending} -> {pairs ++ [pair(pending, payload)], nil}
      end)

    if pending, do: pairs ++ [%{"text" => pending}], else: pairs
  end

  defp pair(nil, payload), do: %{"a2ui" => payload}
  defp pair(text, payload), do: %{"text" => text, "a2ui" => payload}
end

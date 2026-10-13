defmodule A2UIConformance.Handlers.Capabilities do
  @moduledoc false

  # `get_renderer_capabilities` / `get_client_capabilities` (reference
  # harness L905-927): the processor's capabilities for `args.versions`
  # (or `[args.version]`, or the case's protocol version), with inline
  # catalogs when `args.includeInlineCatalogs`, must equal `expect`.

  @behaviour A2UIConformance.Handler

  import ExUnit.Assertions

  alias A2UIConformance.{Case, CatalogFixtures, Matchers}
  alias A2UICore.Processor

  @default_envelope "common_types.json#/$defs/ComponentCommon"

  @impl true
  def run(%Case{raw: raw, protocol_version: protocol_version} = test_case, _context) do
    {:ok, catalogs} = CatalogFixtures.for_case(test_case)
    processor = Processor.new(catalogs)
    args = if is_map(raw["args"]), do: raw["args"], else: %{}

    options = [
      versions: versions(args, protocol_version),
      include_inline_catalogs: args["includeInlineCatalogs"] == true,
      component_envelope_ref: args["componentEnvelopeRef"] || @default_envelope
    ]

    case Processor.renderer_capabilities(processor, options) do
      {:ok, capabilities} ->
        Matchers.assert_json_equal(raw["expect"] || %{}, capabilities, "renderer capabilities")
        :ok

      {:error, error} ->
        flunk("capabilities failed: #{Exception.message(error)}")
    end
  end

  defp versions(%{"versions" => [_ | _] = versions}, _protocol_version), do: versions
  defp versions(%{"version" => version}, _protocol_version), do: [version]
  defp versions(_args, protocol_version), do: [protocol_version || "v0.9"]
end

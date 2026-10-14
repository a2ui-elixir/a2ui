defmodule A2UIConformance.Handlers.A2A do
  @moduledoc false

  # The A2A extension suite (extensions/a2a/a2a_integration.yaml). The
  # Python harness (python/a2ui_agent/tests/conformance/
  # test_a2a_integration.py) runs the part, extension and activation
  # actions; the Kotlin one (kotlin/agent_sdk_legacy/.../
  # A2aConformanceTest.kt) also runs `try_activate_extension` and
  # `handle_rpc`, and is followed for those:
  #
  #   * try_activate_extension: the agent advertises one extension, built
  #     from the base URI and version "0.8"; `expect` says whether the
  #     requested `uris` activate it;
  #   * handle_rpc: the request is answered with `runnerOutput` as the
  #     model's response, and the parts are compared on kind, text, MIME
  #     type and data. The agent negotiates the v1.0 basic catalog for a
  #     request that carries no capabilities. The reference reads the
  #     parts of a message result; `A2UIAgent.A2A.Server` answers with a
  #     task, whose status message holds them.

  @behaviour A2UIConformance.Handler

  import ExUnit.Assertions
  import ExUnit.CaptureLog

  alias A2UIAgent.{A2A, CatalogConfig, Generator}
  alias A2UIAgent.A2A.Server
  alias A2UIConformance.Case
  alias A2UICore.Catalog.Basic

  @impl true
  def run(%Case{action: action, raw: raw}, _context) do
    check(action, raw["args"] || %{}, raw["expect"])
    :ok
  end

  defp check("create_a2ui_part", args, expected) do
    part = A2A.a2ui_part(args["data"], args["version"])

    assert part["kind"] == "data"
    assert part["data"] == args["data"]
    assert part["metadata"]["mimeType"] == expected["mimeType"]
  end

  defp check("is_a2ui_part", args, expected) do
    part = %{"kind" => "data", "data" => %{}, "metadata" => %{"mimeType" => args["mimeType"]}}
    assert A2A.a2ui_part?(part) == expected
  end

  defp check("try_activate_extension", args, expected) do
    advertised = A2A.extension_uri("0.8")

    case A2A.activate(args["uris"], [advertised]) do
      {:ok, uri, _version} ->
        assert expected == true
        assert uri == advertised

      :none ->
        assert expected == false
    end
  end

  defp check("get_extension", args, expected) do
    extension =
      A2A.agent_extension(args["version"],
        accepts_inline_catalogs: args["acceptsInlineCatalogs"] || false,
        supported_catalog_ids: args["supportedCatalogIds"] || []
      )

    assert extension["uri"] == expected["uri"]
    assert extension["params"] == expected["params"]
  end

  defp check("try_activate", args, expected) do
    {activated, version} =
      case A2A.activate(args["requested"], args["advertised"]) do
        {:ok, uri, version} -> {uri, version}
        :none -> {nil, nil}
      end

    assert activated == expected["activated"]
    assert version == expected["version"]
  end

  defp check("select_newest", args, expected),
    do: assert(A2A.select_newest(args["requested"], args["advertised"]) == expected["newest"])

  defp check("handle_rpc", args, expected) do
    basic = Basic.catalog("v1.0")

    options = [
      generator: Generator.new([CatalogConfig.new(basic)]),
      default_capabilities: %{"v1.0" => %{"supportedCatalogIds" => [basic.catalog_id]}}
    ]

    agent = fn _request -> {:ok, args["runnerOutput"]} end

    {{:reply, response, _extensions}, _log} =
      with_log(fn -> Server.handle(args["request"], agent, options) end)

    parts = get_in(response, ["result", "status", "message", "parts"]) || []
    expected_parts = expected["parts"]

    assert length(parts) == length(expected_parts), "parts: #{inspect(parts)}"

    for {part, expected_part} <- Enum.zip(parts, expected_parts),
        do: check_part(part, expected_part)
  end

  defp check_part(part, expected) do
    assert part["kind"] == expected["kind"]
    if Map.has_key?(expected, "text"), do: assert(part["text"] == expected["text"])

    if Map.has_key?(expected, "mimeType"),
      do: assert(part["metadata"]["mimeType"] == expected["mimeType"])

    if Map.has_key?(expected, "data"), do: assert(part["data"] == expected["data"])
  end
end

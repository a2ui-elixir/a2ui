defmodule A2UIConformance.Handlers.SchemaDocument do
  @moduledoc false

  # `agent_to_renderer_schema` / `common_types_schema` (reference harness
  # L1160-1191): the library's schema document for the case's protocol
  # version must equal the `expectFile` specification document exactly
  # (the reference compares sorted-key JSON dumps, so `1` and `1.0`
  # differ).

  @behaviour A2UIConformance.Handler

  alias A2UIConformance.{Case, Matchers, Registry}
  alias A2UICore.Schema.Source

  @impl true
  def run(%Case{action: action, protocol_version: version, raw: raw}, _context) do
    expected =
      [Registry.reference_root(), raw["expectFile"]]
      |> Path.join()
      |> File.read!()
      |> Jason.decode!()

    generated = Source.document(version, logical_name(action))

    Matchers.assert_strict_equal(
      expected,
      generated,
      "#{action} #{version} vs #{raw["expectFile"]}"
    )

    :ok
  end

  defp logical_name("agent_to_renderer_schema"), do: :agent_to_renderer
  defp logical_name("common_types_schema"), do: :common_types
end

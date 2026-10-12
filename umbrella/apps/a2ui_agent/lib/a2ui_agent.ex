defmodule A2UIAgent do
  @moduledoc """
  Agent-side SDK for the A2UI protocol, built on `A2UICore`.

  Provides catalog-derived prompt generation (direct-json format),
  resilient LLM output parsing (`<a2ui-json>` envelopes, streaming chunk
  parsing), a fluent builder DSL for assembling wire messages, and a
  stateless payload validator.
  """
end

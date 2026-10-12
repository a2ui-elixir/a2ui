defmodule A2UIConformance do
  @moduledoc """
  Test harness executing the upstream A2UI YAML conformance suites
  against `A2UICore`/`A2UIAgent`.

  Discovers `conformance/**/*.yaml` from the evidence checkout, dispatches
  each case to an implementation of one of the 51 conformance actions, and
  enforces skip-list hygiene: a skip entry that matches no case is itself
  a failure.

  Not published to Hex.
  """
end

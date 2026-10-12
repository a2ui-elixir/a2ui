defmodule A2UIConformance.Handler do
  @moduledoc false

  # A conformance action handler: runs one case against the library and
  # asserts its expectations with ExUnit assertions (via
  # `A2UIConformance.Matchers`). A handler returns `:ok` when every
  # expectation holds and raises an assertion error otherwise.

  alias A2UIConformance.Case

  @callback run(Case.t(), context :: map()) :: :ok
end

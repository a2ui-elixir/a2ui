defmodule A2UICore do
  @moduledoc """
  Elixir implementation of the [A2UI protocol](https://a2ui.org/) core engine:
  versioned message envelopes, catalog schemas, surface state, data model,
  and processing of agent-to-renderer updates.

  The modules are layered:

    * primitives: `A2UICore.Version`, `A2UICore.Pointer`,
      `A2UICore.Identifier`, `A2UICore.Error`;
    * wire: `A2UICore.Message` and the operations it decodes to;
    * schema validation: `A2UICore.Schema`;
    * state: `A2UICore.State.Surface`, `A2UICore.State.DataModel`;
    * catalogs: `A2UICore.Catalog`, `A2UICore.Catalog.Basic`;
    * resolution: `A2UICore.Resolution.NodeResolver`,
      `A2UICore.Resolution.DataContext`;
    * processing: `A2UICore.Processor`;
    * function calls: `A2UICore.RPC`.

  Start with `A2UICore.Processor` and the
  [processing guide](processing_messages.html).
  """

  alias A2UICore.Version

  @doc """
  Lists the protocol versions this library supports.

  ## Examples

      iex> A2UICore.supported_protocol_versions()
      ["v0.9", "v0.9.1", "v1.0"]

  """
  @spec supported_protocol_versions() :: [String.t()]
  def supported_protocol_versions, do: Version.supported()
end

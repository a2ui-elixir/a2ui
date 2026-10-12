defmodule A2UIConformance.Case do
  @moduledoc false

  # A single conformance case, bound to the suite file it came from.

  @enforce_keys [:name, :suite, :raw]
  defstruct [:name, :suite, :raw, :action, :protocol_version]

  @type t :: %__MODULE__{
          name: String.t(),
          suite: String.t(),
          action: String.t() | nil,
          protocol_version: String.t() | nil,
          raw: map()
        }

  @doc false
  @spec new(String.t(), String.t(), map()) :: t()
  def new(suite, name, raw) when is_map(raw) do
    %__MODULE__{
      name: name,
      suite: suite,
      raw: raw,
      action: raw["action"],
      protocol_version: raw["protocolVersion"]
    }
  end
end

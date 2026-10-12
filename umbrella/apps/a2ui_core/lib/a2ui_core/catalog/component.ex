defmodule A2UICore.Catalog.Component do
  @moduledoc """
  A component a catalog declares: the name a message uses and the JSON
  Schema its payloads must satisfy, plus the v1.0 composition
  constraints (`allowedParents`, `allowedChildren`).
  """

  @moduledoc since: "0.1.0"

  @enforce_keys [:name]
  defstruct [:name, :allowed_parents, :allowed_children, schema: %{}]

  @type t :: %__MODULE__{
          name: String.t(),
          schema: map(),
          allowed_parents: [String.t()] | nil,
          allowed_children: [String.t()] | nil
        }

  @doc """
  Builds a component from a catalog document entry.
  """
  @spec from_schema(String.t(), map()) :: t()
  def from_schema(name, schema) when is_binary(name) and is_map(schema) do
    %__MODULE__{
      name: name,
      schema: schema,
      allowed_parents: schema["allowedParents"],
      allowed_children: schema["allowedChildren"]
    }
  end
end

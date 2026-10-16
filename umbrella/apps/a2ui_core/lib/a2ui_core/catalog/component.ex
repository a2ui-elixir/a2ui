defmodule A2UICore.Catalog.Component do
  @moduledoc """
  A component a catalog declares: the name a message uses and its JSON
  Schema as the catalog document writes it (with its `allOf` mixins and
  references), plus the v1.0 composition constraints (`allowedParents`,
  `allowedChildren`).

  `:from_document` says the schema was read from a catalog document, so
  `A2UICore.Catalog.to_json/1` writes it back exactly; for a component
  defined in code, local references to common types point at the
  common types document instead.
  """

  @moduledoc since: "0.1.0"

  @enforce_keys [:name]
  defstruct [:name, :allowed_parents, :allowed_children, schema: %{}, from_document: false]

  @type t :: %__MODULE__{
          name: String.t(),
          schema: map(),
          allowed_parents: [String.t()] | nil,
          allowed_children: [String.t()] | nil,
          from_document: boolean()
        }

  @doc """
  Builds a component from a catalog document entry.

  Options: `from_document: true` marks a schema read from a document.
  """
  @spec from_schema(String.t(), map(), keyword()) :: t()
  def from_schema(name, schema, options \\ []) when is_binary(name) and is_map(schema) do
    %__MODULE__{
      name: name,
      schema: schema,
      allowed_parents: schema["allowedParents"],
      allowed_children: schema["allowedChildren"],
      from_document: Keyword.get(options, :from_document, false)
    }
  end
end

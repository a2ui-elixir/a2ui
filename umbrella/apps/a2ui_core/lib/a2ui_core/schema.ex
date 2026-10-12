defmodule A2UICore.Schema do
  @moduledoc """
  JSON Schema **Draft 2020-12 subset** validator used by A2UI's catalog,
  envelope, and payload validation.

  `$ref` resolution supports the forms the protocol schemas emit:
  `"#/path"` (local), `"name.json#/path"` (external doc in the registry,
  matched by exact key or URL basename), `"name.json"`, and absolute
  URLs. The `"catalog.json"` placeholder used by the envelope schema is
  just a registry key the caller binds to the active catalog.

  Annotation-only keywords (allowed, never asserted): `title`,
  `description`, `default`, `deprecated`, `x-deprecated-reason`,
  `examples`, `readOnly`, `writeOnly`, `format`, `discriminator`,
  `$schema`, `$id`, `$comment`, `catalogId`, `instructions`,
  `protocolVersion`, `returnType`, `allowedCallers`, `requiresUserActivation`,
  `allowedParents`, `allowedChildren`, `$defs`, `unevaluatedItems` (not
  used by any A2UI schema; rejected as unsupported if encountered).
  """

  alias A2UICore.Error.Detail
  alias A2UICore.Schema.Engine

  @moduledoc since: "0.1.0"

  @type schema :: map() | boolean()

  @typedoc "Registry mapping `$ref` document names/URLs to schema bodies."
  @type registry :: %{optional(String.t()) => schema()}

  @doc """
  Validates `data` against `schema`.

  Options:

  * `:registry` — map of `$ref` targets to document bodies; keys may be
    the reference's href (e.g. `"catalog.json"`, `"common_types.json"`)
    or an absolute URL (`"https://a2ui.org/.../common_types.json"`).
  * `:root` — the document that local `#/...` `$ref`s resolve against
    (defaults to the registry entry keyed `"catalog.json"` when present,
    otherwise to `schema` itself).

  Returns `:ok` on success, or `{:error, [Detail.t()]}`.
  """
  @spec validate(term(), schema(), keyword()) :: :ok | {:error, [Detail.t()]}
  def validate(data, schema, opts \\ []) do
    registry = Keyword.get(opts, :registry, %{})

    root =
      Keyword.get(opts, :root, Map.get(registry, "catalog.json", schema))

    ctx = %{registry: registry, root: root, path: [], ref_depth: 0}

    case Engine.eval(data, schema, ctx) do
      {_annotations, []} -> :ok
      {_annotations, errors} -> {:error, errors}
    end
  end
end

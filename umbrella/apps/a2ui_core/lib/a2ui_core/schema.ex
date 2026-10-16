defmodule A2UICore.Schema do
  @moduledoc """
  JSON Schema **Draft 2020-12** validator used by A2UI's catalog,
  envelope, and payload validation.

  It implements the core, applicator, unevaluated and validation
  vocabularies, and passes every required test of the official
  [JSON Schema Test Suite](https://github.com/json-schema-org/JSON-Schema-Test-Suite)
  for draft 2020-12.

  References (`$ref`, `$dynamicRef`) resolve against the base URI that
  `$id` sets, to JSON pointers (percent-encoded or not), `$anchor` and
  `$dynamicAnchor` names, and embedded resources. A referenced document
  is looked up in the registry by its resolved URI, by the reference as
  written (the protocol schemas name `"common_types.json"`, and
  `"catalog.json"` is a registry key the caller binds to the active
  catalog), by its `$id`, and finally by URL basename.

  A `$schema` naming a meta-schema in the registry that declares its
  `$vocabulary` switches off the keywords of the standard vocabularies
  it leaves out; a vocabulary it requires that this module does not know
  raises `ArgumentError`. Listing the format-assertion vocabulary turns
  on `formats: :assert`.

  `pattern` and `patternProperties` are ECMA-262 regular expressions
  (`A2UICore.Schema.ECMA262`).

  Annotation-only keywords (allowed, never asserted): `title`,
  `description`, `default`, `deprecated`, `x-deprecated-reason`,
  `examples`, `readOnly`, `writeOnly`, `format` (unless `formats: :assert`),
  `content*`, `discriminator`, `$schema`, `$id`, `$anchor`,
  `$dynamicAnchor`, `$vocabulary`, `$comment`, `$defs`, and the catalog
  fields `catalogId`, `instructions`, `protocolVersion`, `returnType`,
  `allowedCallers`, `requiresUserActivation`, `allowedParents`,
  `allowedChildren`, `metadata` and `components`/`functions` (catalog
  containers, entered via `$ref` only).
  """

  alias A2UICore.Error.Detail
  alias A2UICore.Schema.{Engine, Ref}

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
  * `:formats` — `:annotate` (default) treats `format` as an annotation,
    like the reference SDK's validator; `:assert` checks the formats the
    A2UI schemas use (`uri`, `date`, `time`, `date-time`) the way ajv with
    ajv-formats does in the upstream spec test runner.

  Returns `:ok` on success, or `{:error, [Detail.t()]}`.
  """
  @spec validate(term(), schema(), keyword()) :: :ok | {:error, [Detail.t()]}
  def validate(data, schema, opts \\ []) do
    registry = Keyword.get(opts, :registry, %{})

    root =
      Keyword.get(opts, :root, Map.get(registry, "catalog.json", schema))

    base = Ref.document_base(root, nil)

    ctx = %{
      registry: registry,
      root: root,
      base: base,
      doc: root,
      scope: [%{root: root, base: base, doc: root}],
      path: [],
      ref_depth: 0,
      ignored: [],
      formats: Keyword.get(opts, :formats, :annotate)
    }

    case Engine.eval(data, schema, ctx) do
      {_annotations, []} -> :ok
      {_annotations, errors} -> {:error, errors}
    end
  end
end

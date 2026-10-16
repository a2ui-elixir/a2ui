defmodule A2UICore.Catalog do
  @moduledoc """
  A versioned set of component and function definitions: the model of a
  catalog document.

  `from_json/2` reads a document into the model and `to_json/2` writes it
  back, so `from_json(document) |> to_json()` equals the document (apart
  from components and functions its `anyComponent` / `anyFunction`
  unions leave out). Each component and function keeps its schema as
  written, with its `allOf` mixins and references; the catalog keeps the
  document's top-level fields. Two derived views are computed when a
  catalog is built:

    * `validation_schema/1` (also the `:schema` field) — the
      self-contained JSON Schema messages are validated against
      (`A2UICore.Catalog.ValidationSchema`): components flattened,
      common types bundled, every reference local;
    * `resolved_component_schema/2` and `resolved_function_schema/2` —
      an entry's schema with references to the catalog's own `$defs` and
      to peer catalogs written inline, references to common types kept.

  ## Peer catalogs

  A catalog may reuse definitions of a catalog it holds, its peer,
  through an external `$ref` such as
  `simplified_catalog_v1_0.json#/components/Text`. `with_peer_catalogs/2`
  returns a copy linked to peers, and `link_catalogs/2` links a set of
  catalogs to one another; a reference that names no peer stays as
  written, so validating against it fails.

  ## Loading rules

    * a `catalogId` must be known (option or document); the protocol
      version defaults to the document's `protocolVersion`, else `0.9`;
    * `components` maps names to schema objects; `functions` is a map of
      name to definition or a list of `%{"name" => …}` definitions;
    * `$defs.anyComponent` / `$defs.anyFunction`, when they list
      `#/components/X` / `#/functions/X` references, restrict the
      catalog to those names;
    * from v1.0 on, component, property, function and argument names
      must be UAX #31 identifiers (no `@` prefix: that namespace belongs
      to system functions);
    * the theme is read from a top-level `theme`, else `$defs.theme`.

  Failures are `{:error, %A2UICore.Error{category: :catalog}}`.
  """

  alias A2UICore.Catalog.{Component, Document, Function, ReferenceMap, Refs, ValidationSchema}
  alias A2UICore.{Error, Identifier, SemVer, Version}

  @moduledoc since: "0.1.0"

  @dialect "https://json-schema.org/draft/2020-12/schema"
  @union_defs ["anyComponent", "anyFunction"]

  @derive {Inspect, except: [:document_order]}
  defstruct [
    :catalog_id,
    :protocol_version,
    :instructions,
    :schema_dialect,
    :schema_id,
    :title,
    :description,
    :declared_protocol_version,
    :theme_location,
    :functions_form,
    :union_defs,
    :linked_from,
    :source,
    :document_order,
    components: %{},
    functions: %{},
    component_order: [],
    function_order: [],
    theme: %{},
    defs: %{},
    extras: %{},
    declares_catalog_id: true,
    declares_components: false,
    common_types_uri: "common_types.json",
    layout: %{
      declares_defs: false,
      null_unions: [],
      theme_from_document: false,
      defs_from_document: false
    },
    peers: [],
    resolved: %{components: %{}, functions: %{}, defs: %{}, theme: %{}},
    schema: %{},
    ref_specs: %{}
  ]

  @type t :: %__MODULE__{
          catalog_id: String.t(),
          protocol_version: String.t(),
          instructions: String.t() | nil,
          schema_dialect: String.t() | nil,
          schema_id: String.t() | nil,
          title: String.t() | nil,
          description: String.t() | nil,
          declared_protocol_version: String.t() | nil,
          theme_location: String.t() | nil,
          functions_form: :map | :list | nil,
          union_defs: %{optional(String.t()) => map() | nil} | nil,
          linked_from: t() | nil,
          source: t() | nil,
          document_order: Jason.OrderedObject.t() | nil,
          components: %{optional(String.t()) => Component.t()},
          functions: %{optional(String.t()) => Function.t()},
          component_order: [String.t()],
          function_order: [String.t()],
          theme: map(),
          defs: map(),
          extras: map(),
          declares_catalog_id: boolean(),
          declares_components: boolean(),
          common_types_uri: String.t(),
          layout: map(),
          peers: [t()],
          resolved: map(),
          schema: map(),
          ref_specs: %{optional(String.t()) => A2UICore.Catalog.RefSpec.t()}
        }

  @doc """
  Assembles a catalog from parts (a catalog defined in code).

  Options: `:components` and `:functions` (lists of
  `A2UICore.Catalog.Component` / `A2UICore.Catalog.Function`), `:theme`
  (a schema), `:instructions`, `:defs` (the catalog's own `$defs`).
  """
  @spec new(String.t(), String.t(), keyword()) :: {:ok, t()} | {:error, Error.t()}
  def new(catalog_id, protocol_version, options \\ []) do
    components = Keyword.get(options, :components, [])
    functions = Keyword.get(options, :functions, [])
    theme = Keyword.get(options, :theme) || %{}

    with :ok <- check_version(protocol_version),
         :ok <- check_names(protocol_version, Enum.map(components, & &1.name), "component"),
         :ok <- check_function_names(protocol_version, functions) do
      fields = %{
        catalog_id: catalog_id,
        protocol_version: protocol_version,
        components: components,
        functions: functions,
        theme: theme,
        instructions: options[:instructions],
        defs: Map.drop(Keyword.get(options, :defs) || %{}, @union_defs),
        schema_dialect: @dialect,
        declared_protocol_version: SemVer.to_canonical(protocol_version) || protocol_version,
        theme_location:
          if(theme != %{} and not SemVer.at_least(protocol_version, "v1.0"), do: "$defs")
      }

      {:ok, build(fields)}
    end
  end

  @doc """
  Like `new/3`, raising `A2UICore.Error` on failure.
  """
  @spec new!(String.t(), String.t(), keyword()) :: t()
  def new!(catalog_id, protocol_version, options \\ []),
    do: unwrap!(new(catalog_id, protocol_version, options))

  @doc """
  Builds a catalog from a catalog document: a map, or a
  `Jason.OrderedObject` (`Jason.decode(text, objects: :ordered_objects)`),
  whose key order then orders the components and functions, as the
  `anyComponent` / `anyFunction` unions of the validation schema list
  them. A map's entries are ordered by name.

  Options: `:catalog_id` and `:protocol_version` take precedence over
  the document's `catalogId` / `protocolVersion`.
  """
  @spec from_json(map() | Jason.OrderedObject.t(), keyword()) :: {:ok, t()} | {:error, Error.t()}
  def from_json(document, options \\ []) when is_map(document) do
    with {:ok, fields} <- Document.parse(document, options),
         :ok <- check_version(fields.protocol_version) do
      {:ok, build(fields)}
    end
  end

  @doc """
  Like `from_json/2`, raising `A2UICore.Error` on failure.
  """
  @spec from_json!(map() | Jason.OrderedObject.t(), keyword()) :: t()
  def from_json!(document, options \\ []), do: unwrap!(from_json(document, options))

  @doc """
  The catalog document, with references left as written: common types
  stay external (`common_types.json#/$defs/X`) and nothing is bundled.
  For the schema messages validate against, see `validation_schema/1`.

  With `ordered: true` the objects of the document are
  `Jason.OrderedObject`s, so that `Jason.encode!/1` writes it in the
  reference's key order: the top-level fields in a fixed order, and what
  was read from a document decoded with `objects: :ordered_objects` in
  that document's order.
  """
  @spec to_json(t(), keyword()) :: map() | Jason.OrderedObject.t()
  def to_json(%__MODULE__{} = catalog, options \\ []) do
    if Keyword.get(options, :ordered, false),
      do: Document.build(catalog),
      else: Document.to_plain(Document.build(catalog))
  end

  @doc """
  The self-contained schema messages validate against.
  """
  @spec validation_schema(t()) :: map()
  def validation_schema(%__MODULE__{schema: schema}), do: schema

  @doc """
  A component's schema with references to the catalog's own `$defs` and
  to peers written inline, or `nil` for an unknown component.
  """
  @spec resolved_component_schema(t(), String.t()) :: term()
  def resolved_component_schema(%__MODULE__{resolved: resolved}, name),
    do: Map.get(resolved.components, name)

  @doc """
  A function's schema with references resolved (see
  `resolved_component_schema/2`), or `nil`.
  """
  @spec resolved_function_schema(t(), String.t()) :: term()
  def resolved_function_schema(%__MODULE__{resolved: resolved}, name),
    do: Map.get(resolved.functions, name)

  @doc """
  The theme schema with references resolved.
  """
  @spec resolved_theme_schema(t()) :: map()
  def resolved_theme_schema(%__MODULE__{resolved: resolved}), do: resolved.theme

  @doc """
  A copy of `catalog` for catalog transformers. Options: `:components`
  and `:functions` (the copy's entries; default: this catalog's) and
  `:defs` (its own `$defs`; default: this catalog's, without those only
  dropped entries referenced). An authored `anyComponent` /
  `anyFunction` union no longer describes changed entries, so it is
  listed from them instead.
  """
  @spec copy_with(t(), keyword()) :: t()
  def copy_with(%__MODULE__{} = catalog, options \\ []) do
    components =
      Keyword.get(options, :components) || ordered(catalog.components, catalog.component_order)

    functions =
      Keyword.get(options, :functions) || ordered(catalog.functions, catalog.function_order)

    {union_defs, null_unions} =
      relist_unions(catalog, Enum.map(components, & &1.name), Enum.map(functions, & &1.name))

    defs = Keyword.get(options, :defs) || kept_defs(catalog, components, functions, union_defs)

    catalog
    |> Map.from_struct()
    |> Map.merge(%{
      components: components,
      functions: functions,
      defs: Map.drop(defs, @union_defs),
      union_defs: union_defs,
      layout: %{
        catalog.layout
        | null_unions: null_unions,
          defs_from_document: catalog.layout.defs_from_document and is_nil(options[:defs])
      },
      source: bare(catalog.source || link_origin(catalog)),
      linked_from: nil
    })
    |> build()
  end

  defp ordered(entries, order), do: Enum.map(order, &Map.fetch!(entries, &1))

  defp relist_unions(%{union_defs: nil, layout: layout}, _components, _functions),
    do: {nil, layout.null_unions}

  defp relist_unions(catalog, components, functions) do
    changed = %{
      "anyComponent" => components != catalog.component_order,
      "anyFunction" => functions != catalog.function_order
    }

    Enum.reduce(changed, {catalog.union_defs, catalog.layout.null_unions}, fn
      {name, true}, {unions, nulls} when is_map_key(unions, name) ->
        {Map.put(unions, name, nil), List.delete(nulls, name)}

      _unchanged, acc ->
        acc
    end)
  end

  defp kept_defs(catalog, components, functions, union_defs) do
    old_reachable = Refs.reachable_defs(document_roots(catalog), catalog.defs)

    orphans =
      for {name, schema} <- catalog.defs, not MapSet.member?(old_reachable, name), do: schema

    roots =
      Enum.map(components, & &1.schema) ++
        Enum.map(functions, & &1.schema) ++
        [catalog.theme | Map.values(catalog.extras)] ++
        authored_unions(union_defs) ++ orphans

    new_reachable = Refs.reachable_defs(roots, catalog.defs)

    for {name, schema} <- catalog.defs,
        not MapSet.member?(old_reachable, name) or MapSet.member?(new_reachable, name),
        into: %{},
        do: {name, schema}
  end

  defp document_roots(catalog) do
    Enum.map(Map.values(catalog.components), & &1.schema) ++
      Enum.map(Map.values(catalog.functions), & &1.schema) ++
      [catalog.theme | Map.values(catalog.extras)] ++ authored_unions(catalog.union_defs)
  end

  defp authored_unions(nil), do: []
  defp authored_unions(unions), do: for({_name, schema} <- unions, schema != nil, do: schema)

  @doc """
  Returns a copy of `catalog` under another id, optionally without its
  functions (`functions: false`).
  """
  @spec derive(t(), String.t(), keyword()) :: t()
  def derive(%__MODULE__{} = catalog, catalog_id, options \\ []) do
    options = if Keyword.get(options, :functions, true), do: [], else: [functions: []]

    catalog
    |> Map.put(:catalog_id, catalog_id)
    |> copy_with(options)
  end

  @doc """
  A copy of `catalog` that resolves cross-catalog references into
  `peers`, after the peers it already has (without duplicates). For a
  peer derived from another catalog by `copy_with/2` (a pruned catalog),
  the catalog it was derived from comes first, so references to entries
  pruned from it still resolve. Returns `catalog` itself when `peers`
  adds none.
  """
  @spec with_peer_catalogs(t(), [t()]) :: t()
  def with_peer_catalogs(%__MODULE__{} = catalog, peers) when is_list(peers) do
    origin = link_origin(catalog)

    {existing, _seen, changed?} =
      peers
      |> Enum.flat_map(&peer_candidates/1)
      |> Enum.reduce(
        {catalog.peers, MapSet.new([key(origin) | Enum.map(catalog.peers, &key/1)]), false},
        fn
          candidate, {acc, seen, changed?} ->
            if MapSet.member?(seen, key(candidate)),
              do: {acc, seen, changed?},
              else: {acc ++ [bare(candidate)], MapSet.put(seen, key(candidate)), true}
        end
      )

    if changed? do
      catalog
      |> Map.from_struct()
      |> Map.merge(%{
        components: ordered(catalog.components, catalog.component_order),
        functions: ordered(catalog.functions, catalog.function_order),
        peers: existing,
        linked_from: bare(origin)
      })
      |> build()
    else
      catalog
    end
  end

  defp peer_candidates(%__MODULE__{} = peer),
    do: Enum.reject([peer.source, link_origin(peer)], &is_nil/1)

  defp peer_candidates(_other), do: []

  defp link_origin(%__MODULE__{linked_from: %__MODULE__{} = origin}), do: origin
  defp link_origin(catalog), do: catalog

  defp bare(nil), do: nil
  defp bare(%__MODULE__{} = catalog), do: %{catalog | peers: [], linked_from: nil, source: nil}

  defp key(catalog),
    do: {catalog.catalog_id, catalog.schema_id, catalog.component_order, catalog.function_order}

  @doc """
  The catalogs linked to one another for cross-catalog references: each
  catalog with a reference into another document is replaced by a copy
  whose peers are `extra_peers` followed by the other catalogs; the
  others are returned unchanged.
  """
  @spec link_catalogs([t()], [t()]) :: [t()]
  def link_catalogs(catalogs, extra_peers \\ [])

  def link_catalogs(catalogs, extra_peers) when length(catalogs) + length(extra_peers) < 2,
    do: catalogs

  def link_catalogs(catalogs, extra_peers) when is_list(catalogs) do
    indexed = Enum.with_index(catalogs)
    Enum.map(indexed, &link_one(&1, indexed, extra_peers))
  end

  defp link_one({catalog, index}, indexed, extra_peers) do
    if cross_document?(catalog) do
      others = for {other, i} <- indexed, i != index, do: other
      with_peer_catalogs(catalog, extra_peers ++ others)
    else
      catalog
    end
  end

  @doc """
  Writes the local references of `node` (resolved in `root`, usually the
  catalog's document) and its references into the catalog's peers
  inline, keeping references to common types. A prompt uses this to find
  the common types a catalog reaches through its peers.
  """
  @spec inline_refs(t(), term(), map()) :: term()
  def inline_refs(%__MODULE__{} = catalog, node, root) when is_map(root),
    do: Refs.inline(node, root, peer_entries(catalog), ValidationSchema.common_names())

  defp peer_entries(catalog) do
    Enum.map(catalog.peers, fn peer ->
      %{catalog_id: peer.catalog_id, schema_id: peer.schema_id, document: to_json(peer)}
    end)
  end

  @doc """
  Whether the catalog document has a `$ref` that may name a peer
  catalog.
  """
  @spec cross_document?(t()) :: boolean()
  def cross_document?(%__MODULE__{} = catalog), do: Refs.cross_document?(to_json(catalog))

  @doc """
  Attaches function implementations by name. Names the catalog does
  not declare are ignored.
  """
  @spec put_implementations(t(), %{optional(String.t()) => Function.execute()}) :: t()
  def put_implementations(%__MODULE__{} = catalog, implementations)
      when is_map(implementations) do
    functions =
      Map.new(catalog.functions, fn {name, function} ->
        case implementations do
          %{^name => execute} -> {name, Function.with_execute(function, execute)}
          _other -> {name, function}
        end
      end)

    %{catalog | functions: functions}
  end

  @doc """
  Adds functions the runtime supplies (system functions such as
  `@index`), replacing any of the same name. They are evaluated like the
  catalog's own but are not part of its document or validation schema.
  """
  @spec put_system_functions(t(), [Function.t()]) :: t()
  def put_system_functions(%__MODULE__{} = catalog, functions) when is_list(functions) do
    Enum.reduce(functions, catalog, fn %Function{name: name} = function, acc ->
      order =
        if name in acc.function_order, do: acc.function_order, else: acc.function_order ++ [name]

      %{acc | functions: Map.put(acc.functions, name, function), function_order: order}
    end)
  end

  @doc """
  The self-contained catalog schema document; see `validation_schema/1`.
  """
  @spec to_schema(t()) :: map()
  def to_schema(%__MODULE__{} = catalog), do: validation_schema(catalog)

  @doc """
  Looks a component up by name.
  """
  @spec get_component(t(), term()) :: Component.t() | nil
  def get_component(%__MODULE__{components: components}, name) when is_binary(name),
    do: Map.get(components, name)

  def get_component(%__MODULE__{}, _name), do: nil

  @doc """
  Looks a function up by name. As in the reference, a name that differs
  from a declared one only in the case of its first letter also matches.
  """
  @spec get_function(t(), term()) :: Function.t() | nil
  def get_function(%__MODULE__{}, name) when not is_binary(name) or name == "", do: nil

  def get_function(%__MODULE__{functions: functions}, name) do
    {first, rest} = String.split_at(name, 1)

    Map.get(functions, name) || Map.get(functions, String.downcase(first) <> rest) ||
      Map.get(functions, String.upcase(first) <> rest)
  end

  @doc """
  The child-reference analysis of a component, or `nil` for an unknown
  one.
  """
  @spec ref_spec(t(), String.t()) :: A2UICore.Catalog.RefSpec.t() | nil
  def ref_spec(%__MODULE__{ref_specs: ref_specs}, name), do: Map.get(ref_specs, name)

  @doc """
  Whether the catalog's protocol version is v1.0 or later.
  """
  @spec v1?(t()) :: boolean()
  def v1?(%__MODULE__{protocol_version: version}), do: SemVer.at_least(version, "v1.0")

  @doc """
  The `$defs` of the protocol version's `common_types.json`, with
  cross-document references made local. Empty for an unsupported
  version.
  """
  @spec common_definitions(String.t()) :: map()
  def common_definitions(version) do
    with {:ok, canonical} <- Version.to_protocol_version(version),
         true <- canonical in Version.supported() do
      ValidationSchema.published_defs(canonical)
    else
      _ -> %{}
    end
  end

  @doc false
  # Rewrites references into `common_types.json` / `catalog.json` as
  # local `#/$defs/…` pointers.
  @spec localize(term()) :: term()
  def localize(node), do: Refs.normalize(node)

  # -- building ------------------------------------------------------------------------

  defp build(fields) do
    components = fields.components
    functions = fields.functions

    catalog =
      struct!(
        __MODULE__,
        fields
        |> Map.drop([:__struct__])
        |> Map.merge(%{
          components: Map.new(components, &{&1.name, &1}),
          functions: Map.new(functions, &{&1.name, &1}),
          component_order: Enum.map(components, & &1.name),
          function_order: Enum.map(functions, & &1.name)
        })
      )

    resolved = resolve(catalog)
    catalog = %{catalog | resolved: resolved}
    schema = ValidationSchema.build(catalog)

    %{
      catalog
      | schema: schema,
        ref_specs:
          ReferenceMap.build(%{
            "components" => resolved.components,
            "$defs" => schema["$defs"] || %{}
          })
    }
  end

  defp resolve(catalog) do
    peers = peer_entries(catalog)

    own_defs =
      if catalog.theme != %{} and catalog.theme_location == "$defs",
        do: Map.put(catalog.defs, "theme", catalog.theme),
        else: catalog.defs

    components = Map.new(catalog.components, fn {name, c} -> {name, c.schema} end)

    functions =
      for {name, %Function{schema: %{} = schema}} <- catalog.functions,
          into: %{},
          do: {name, schema}

    root =
      Refs.normalize(
        %{"$defs" => own_defs, "components" => components, "functions" => functions},
        peers
      )

    preserved = ValidationSchema.common_names()

    resolve = fn node ->
      node
      |> Refs.normalize(peers)
      |> Refs.inline(root, peers, preserved)
      |> Refs.normalize(peers)
    end

    %{
      components: Map.new(components, fn {name, schema} -> {name, resolve.(schema)} end),
      functions: Map.new(functions, fn {name, schema} -> {name, resolve.(schema)} end),
      defs: Map.new(catalog.defs, fn {name, schema} -> {name, resolve.(schema)} end),
      theme: if(catalog.theme == %{}, do: %{}, else: resolve.(catalog.theme))
    }
  end

  # -- identifier checks ------------------------------------------------------------

  defp check_version(version) do
    case Version.to_protocol_version(version) do
      {:ok, canonical} ->
        if canonical in Version.supported(),
          do: :ok,
          else: {:error, catalog_error("Unsupported protocol version: #{inspect(version)}")}

      :error ->
        {:error, catalog_error("Unsupported protocol version: #{inspect(version)}")}
    end
  end

  defp check_names(version, names, kind) do
    if SemVer.at_least(version, "v1.0") do
      case Enum.find(names, &(not Identifier.valid?(&1))) do
        nil -> :ok
        name -> {:error, catalog_error("Invalid UAX #31 #{kind} identifier: '#{name}'")}
      end
    else
      :ok
    end
  end

  defp check_function_names(version, functions) do
    system = ValidationSchema.system_names(version)

    check_names(
      version,
      for(%Function{name: name} <- functions, name not in system, do: name),
      "function"
    )
  end

  # -- helpers ----------------------------------------------------------------------

  defp catalog_error(message), do: Error.new(:catalog, "CATALOG_ERROR", message)

  defp unwrap!({:ok, value}), do: value
  defp unwrap!({:error, error}), do: raise(error)
end

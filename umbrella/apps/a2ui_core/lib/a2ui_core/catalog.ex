defmodule A2UICore.Catalog do
  @moduledoc """
  A versioned set of component and function definitions.

  A catalog is built from a catalog JSON document (`from_json/2`) or
  assembled from parts (`new/3`). Either way it carries:

    * `:components` — `%{name => A2UICore.Catalog.Component}`,
    * `:functions` — `%{name => A2UICore.Catalog.Function}`; a function
      with an `:execute` implementation can be evaluated, one without is
      schema-only (what an agent works with),
    * `:schema` — the self-contained catalog schema (`to_schema/1`):
      every cross-document reference made local and the common-type
      definitions the catalog uses bundled into `$defs`,
    * `:ref_specs` — which component properties reference children.

  ## Loading rules

  `from_json/2` accepts the published catalog documents and the inline
  catalogs of renderer capabilities:

    * a `catalogId` and a protocol version must be known (as options or
      in the document);
    * references to `common_types.json` / `catalog.json` are rewritten to
      local `#/$defs/…` pointers;
    * `components` must map names to schema objects; `functions` is a
      map of name → schema or a list of `%{"name" => …}` definitions;
    * `$defs.anyComponent` / `$defs.anyFunction`, when they list
      `#/components/X` / `#/functions/X` references, restrict the
      catalog to those names;
    * from v1.0 on, component, property, function and argument names
      must be UAX #31 identifiers (`@`-prefixed system names allowed);
    * `theme` (top level or `$defs.theme`) and `instructions` are kept.

  Failures are `{:error, %A2UICore.Error{category: :catalog}}`.
  """

  alias A2UICore.Catalog.{Component, Function, ReferenceMap}
  alias A2UICore.{Error, Identifier, SemVer, Version}
  alias A2UICore.Schema.Source

  @moduledoc since: "0.1.0"

  @draft "https://json-schema.org/draft/2020-12/schema"
  @localizable_documents ["common_types.json", "catalog.json"]
  @system_functions ["@index"]

  defstruct [
    :catalog_id,
    :protocol_version,
    :instructions,
    components: %{},
    functions: %{},
    theme: %{},
    defs: %{},
    schema: %{},
    ref_specs: %{}
  ]

  @type t :: %__MODULE__{
          catalog_id: String.t(),
          protocol_version: String.t(),
          instructions: String.t() | nil,
          components: %{optional(String.t()) => Component.t()},
          functions: %{optional(String.t()) => Function.t()},
          theme: map(),
          defs: map(),
          schema: map(),
          ref_specs: %{optional(String.t()) => A2UICore.Catalog.RefSpec.t()}
        }

  @doc """
  Assembles a catalog from parts.

  Options: `:components` and `:functions` (lists of
  `A2UICore.Catalog.Component` / `A2UICore.Catalog.Function`), `:theme`
  (a schema), `:instructions`, `:defs` (extra `$defs`).
  """
  @spec new(String.t(), String.t(), keyword()) :: {:ok, t()} | {:error, Error.t()}
  def new(catalog_id, protocol_version, options \\ []) do
    components = options |> Keyword.get(:components, []) |> Map.new(&{&1.name, &1})
    functions = options |> Keyword.get(:functions, []) |> Map.new(&{&1.name, &1})

    with :ok <- check_version(protocol_version),
         :ok <- check_names(protocol_version, Map.keys(components), "component"),
         :ok <- check_names(protocol_version, Map.keys(functions), "function") do
      assemble(%{
        catalog_id: catalog_id,
        protocol_version: protocol_version,
        components: components,
        functions: functions,
        theme: Keyword.get(options, :theme) || %{},
        instructions: options[:instructions],
        defs: Keyword.get(options, :defs) || %{},
        flatten: false
      })
    end
  end

  @doc """
  Like `new/3`, raising `A2UICore.Error` on failure.
  """
  @spec new!(String.t(), String.t(), keyword()) :: t()
  def new!(catalog_id, protocol_version, options \\ []),
    do: unwrap!(new(catalog_id, protocol_version, options))

  @doc """
  Builds a catalog from a catalog JSON document.

  Options: `:catalog_id` and `:protocol_version` override (or supply)
  the document's `catalogId` / `protocolVersion`; `flatten: true`
  rewrites `allOf` component envelopes (a common-types mixin plus an
  object) into one flat `properties` schema, so consumers that read
  property lists need not resolve composition.
  """
  @spec from_json(map(), keyword()) :: {:ok, t()} | {:error, Error.t()}
  def from_json(document, options \\ []) when is_map(document) do
    catalog_id = options[:catalog_id] || document["catalogId"]
    protocol_version = options[:protocol_version] || document["protocolVersion"]

    cond do
      not present?(catalog_id) ->
        {:error, catalog_error("catalog_id must be provided or exist in catalog_schema.")}

      not present?(protocol_version) ->
        {:error, catalog_error("protocol_version must be provided.")}

      true ->
        load(localize(document), catalog_id, protocol_version, options[:flatten] == true)
    end
  end

  @doc """
  Like `from_json/2`, raising `A2UICore.Error` on failure.
  """
  @spec from_json!(map(), keyword()) :: t()
  def from_json!(document, options \\ []), do: unwrap!(from_json(document, options))

  @doc """
  Returns a copy of `catalog` under another id, optionally without its
  functions (`functions: false`).
  """
  @spec derive(t(), String.t(), keyword()) :: t()
  def derive(%__MODULE__{} = catalog, catalog_id, options \\ []) do
    functions = if Keyword.get(options, :functions, true), do: catalog.functions, else: %{}

    catalog
    |> Map.merge(%{catalog_id: catalog_id, functions: functions})
    |> Map.update!(:defs, &Map.drop(&1, ["anyComponent", "anyFunction"]))
    |> Map.from_struct()
    |> assemble!()
  end

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
  The self-contained catalog schema document.
  """
  @spec to_schema(t()) :: map()
  def to_schema(%__MODULE__{schema: schema}), do: schema

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

  # -- loading ------------------------------------------------------------------

  defp load(document, catalog_id, protocol_version, flatten?) do
    with :ok <- check_version(protocol_version),
         {:ok, schemas} <- component_schemas(document),
         {:ok, function_entries} <- function_entries(document["functions"], catalog_id),
         :ok <- check_component_names(protocol_version, schemas),
         :ok <- check_function_names(protocol_version, function_entries) do
      defs = Map.get(document, "$defs") || %{}
      permitted = permitted_names(defs["anyComponent"], "#/components/")
      permitted_functions = permitted_names(defs["anyFunction"], "#/functions/")

      components =
        for {name, schema} <- schemas, allowed?(permitted, name), into: %{} do
          {name, Component.from_schema(name, schema)}
        end

      functions =
        for {name, schema} <- function_entries, allowed?(permitted_functions, name), into: %{} do
          {name, Function.from_schema(name, schema)}
        end

      assemble(%{
        catalog_id: catalog_id,
        protocol_version: protocol_version,
        components: components,
        functions: functions,
        theme: document["theme"] || defs["theme"] || %{},
        instructions: document["instructions"],
        defs: defs,
        flatten: flatten?
      })
    end
  end

  defp component_schemas(%{"components" => components}) when is_map(components) do
    case Enum.find(components, fn {_name, schema} -> not is_map(schema) end) do
      nil ->
        {:ok, components}

      {name, schema} ->
        {:error,
         catalog_error(
           "Component '#{name}' schema must be a JSON schema object, got #{type_name(schema)}."
         )}
    end
  end

  defp component_schemas(%{"components" => other}) when not is_nil(other),
    do:
      {:error, catalog_error("Catalog 'components' must be an object mapping names to schemas.")}

  defp component_schemas(_document), do: {:ok, %{}}

  defp function_entries(nil, _catalog_id), do: {:ok, []}

  defp function_entries(functions, catalog_id) when is_map(functions) do
    Enum.reduce_while(functions, {:ok, []}, fn
      {name, spec}, {:ok, acc} when is_map(spec) ->
        {:cont, {:ok, [{name, spec} | acc]}}

      {name, spec}, _acc ->
        {:halt,
         {:error,
          catalog_error(
            "Catalog '#{catalog_id}' function '#{name}' must be a JSON schema object, " <>
              "got #{type_name(spec)}."
          )}}
    end)
  end

  defp function_entries(functions, catalog_id) when is_list(functions) do
    functions
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, []}, fn
      {%{"name" => name} = entry, _index}, {:ok, acc} when is_binary(name) and name != "" ->
        {:cont, {:ok, [{name, Map.delete(entry, "name")} | acc]}}

      {entry, index}, _acc when is_map(entry) ->
        {:halt,
         {:error,
          catalog_error(
            "Catalog '#{catalog_id}' function definition #{index} is missing a non-empty " <>
              "'name' string."
          )}}

      {entry, index}, _acc ->
        {:halt,
         {:error,
          catalog_error(
            "Catalog '#{catalog_id}' function definition #{index} must be an object, " <>
              "got #{type_name(entry)}."
          )}}
    end)
  end

  defp function_entries(other, catalog_id) do
    {:error,
     catalog_error(
       "Catalog '#{catalog_id}' 'functions' must be an object or a list of definitions, " <>
         "got #{type_name(other)}."
     )}
  end

  defp permitted_names(%{"oneOf" => entries}, prefix) when is_list(entries) do
    for %{"$ref" => ref} <- entries, is_binary(ref), String.starts_with?(ref, prefix) do
      ref |> String.split("/") |> List.last()
    end
  end

  defp permitted_names(_any, _prefix), do: []

  defp allowed?([], _name), do: true
  defp allowed?(permitted, name), do: name in permitted

  # -- identifier checks --------------------------------------------------------

  defp check_version(version) do
    case Version.to_protocol_version(version) do
      {:ok, canonical} ->
        if canonical in Version.supported() do
          :ok
        else
          {:error, catalog_error("Unsupported protocol version: #{inspect(version)}")}
        end

      :error ->
        {:error, catalog_error("Unsupported protocol version: #{inspect(version)}")}
    end
  end

  defp check_names(version, names, kind) do
    if SemVer.at_least(version, "v1.0") do
      names
      |> Enum.find(&(not Identifier.valid?(&1)))
      |> case do
        nil -> :ok
        name -> {:error, catalog_error("Invalid UAX #31 #{kind} identifier: '#{name}'")}
      end
    else
      :ok
    end
  end

  defp check_component_names(version, schemas) do
    if SemVer.at_least(version, "v1.0") do
      with :ok <- check_names(version, Map.keys(schemas), "component") do
        check_property_names(schemas)
      end
    else
      :ok
    end
  end

  defp check_property_names(schemas) do
    invalid =
      Enum.find_value(schemas, fn {name, schema} ->
        with %{"properties" => properties} when is_map(properties) <- schema,
             property when not is_nil(property) <-
               Enum.find(Map.keys(properties), &(not Identifier.valid?(&1))) do
          {name, property}
        else
          _ -> nil
        end
      end)

    case invalid do
      nil ->
        :ok

      {component, property} ->
        {:error,
         catalog_error(
           "Invalid UAX #31 property identifier: '#{property}' in component '#{component}'"
         )}
    end
  end

  defp check_function_names(version, entries) do
    if SemVer.at_least(version, "v1.0") do
      with :ok <- check_names(version, Enum.map(entries, &elem(&1, 0)), "function") do
        check_argument_names(entries)
      end
    else
      :ok
    end
  end

  defp check_argument_names(entries) do
    invalid =
      Enum.find_value(entries, fn {name, spec} ->
        properties =
          cond do
            is_map(spec["properties"]) -> spec["properties"]
            is_map(spec["parameters"]) -> spec["parameters"]
            true -> %{}
          end

        case Enum.find(Map.keys(properties), &(not Identifier.valid?(&1))) do
          nil -> nil
          argument -> {name, argument}
        end
      end)

    case invalid do
      nil ->
        :ok

      {function, argument} ->
        {:error,
         catalog_error(
           "Invalid UAX #31 argument identifier: '#{argument}' in function '#{function}'"
         )}
    end
  end

  # -- schema assembly ----------------------------------------------------------

  defp assemble!(fields), do: fields |> Map.put(:flatten, false) |> assemble() |> unwrap!()

  defp assemble(fields) do
    version = fields.protocol_version
    v1? = SemVer.at_least(version, "v1.0")
    lookup = Map.merge(common_definitions(version), fields.defs)

    components =
      Map.new(fields.components, fn {name, component} ->
        schema = shape_component(name, component.schema, v1?, lookup, fields.flatten)
        {name, %{component | schema: schema}}
      end)

    component_defs =
      Enum.reduce(fields.components, %{}, fn {_name, component}, acc ->
        case component.schema do
          %{"$defs" => defs} when is_map(defs) -> Map.merge(acc, defs)
          _no_defs -> acc
        end
      end)

    own_defs =
      component_defs
      |> Map.merge(fields.defs)
      |> Map.drop(["anyComponent", "anyFunction"])
      |> put_theme(fields.theme)

    declared_functions =
      for {name, function} <- fields.functions, name not in @system_functions, into: %{} do
        {name, function}
      end

    schema =
      %{"$schema" => @draft, "catalogId" => fields.catalog_id}
      |> put_present("instructions", fields.instructions)
      |> put_present(
        "components",
        Map.new(components, fn {n, c} -> {n, strip_defs(c.schema)} end)
      )
      |> put_present("functions", Map.new(declared_functions, fn {n, f} -> {n, f.schema} end))
      |> put_defs(own_defs, fields.defs, components, declared_functions)
      |> bundle_common_types(version)

    catalog = %__MODULE__{
      catalog_id: fields.catalog_id,
      protocol_version: version,
      instructions: fields.instructions,
      components: components,
      functions: fields.functions,
      theme: fields.theme,
      defs: fields.defs,
      schema: schema,
      ref_specs: ReferenceMap.build(schema)
    }

    {:ok, catalog}
  end

  defp put_theme(defs, theme) when map_size(theme) > 0, do: Map.put(defs, "theme", theme)
  defp put_theme(defs, _theme), do: defs

  defp put_defs(schema, own_defs, authored, components, functions) do
    defs =
      own_defs
      |> put_any("anyComponent", authored["anyComponent"], components, "#/components/",
        discriminator: true
      )
      |> put_any("anyFunction", authored["anyFunction"], functions, "#/functions/")

    put_present(schema, "$defs", defs)
  end

  defp put_any(defs, _key, authored, _members, _prefix, _opts \\ [])

  defp put_any(defs, key, %{"oneOf" => _} = authored, _members, _prefix, _opts),
    do: Map.put(defs, key, authored)

  defp put_any(defs, _key, _authored, members, _prefix, _opts) when map_size(members) == 0,
    do: defs

  defp put_any(defs, key, _authored, members, prefix, opts) do
    refs = members |> Map.keys() |> Enum.sort() |> Enum.map(&%{"$ref" => prefix <> &1})
    union = %{"oneOf" => refs}

    union =
      if opts[:discriminator],
        do: Map.put(union, "discriminator", %{"propertyName" => "component"}),
        else: union

    Map.put(defs, key, union)
  end

  defp strip_defs(schema), do: Map.delete(schema, "$defs")

  defp put_present(map, _key, value) when value in [nil, "", %{}], do: map
  defp put_present(map, key, value), do: Map.put(map, key, value)

  # A component schema is normalised the way the reference's catalog
  # schema emits it: `component` is a const, `additionalProperties`
  # becomes `unevaluatedProperties`, and a flat v0.9 schema declares the
  # `id` and `component` properties of the envelope. `allOf` envelopes
  # are left as authored unless flattening was asked for.
  defp shape_component(name, schema, v1?, lookup, flatten?) do
    {schema, flattened?} =
      if flatten?, do: flatten(schema, lookup), else: {schema, false}

    schema
    |> declare_envelope(name, v1?, flattened?)
    |> component_const(name)
    |> unevaluated()
  end

  defp component_const(%{"properties" => %{"component" => property} = properties} = schema, name)
       when is_map(property) do
    property =
      if Map.has_key?(property, "const"), do: property, else: Map.put(property, "const", name)

    required = List.wrap(schema["required"])
    required = if "component" in required, do: required, else: required ++ ["component"]

    schema
    |> Map.put("properties", Map.put(properties, "component", property))
    |> Map.put("required", required)
  end

  defp component_const(schema, _name), do: schema

  defp unevaluated(%{"unevaluatedProperties" => _} = schema), do: schema

  defp unevaluated(%{"additionalProperties" => value} = schema),
    do: schema |> Map.delete("additionalProperties") |> Map.put("unevaluatedProperties", value)

  defp unevaluated(schema), do: schema

  # Before v1.0 a flat component schema (no `allOf`) names the envelope
  # properties itself; from v1.0 on only a flattened one needs
  # `component` added (its `id` comes from the common type).
  defp declare_envelope(%{"properties" => properties} = schema, name, v1?, flattened?)
       when is_map(properties) and not is_map_key(schema, "allOf") and (not v1? or flattened?) do
    properties =
      properties
      |> Map.put_new("id", %{"$ref" => "#/$defs/ComponentId"})
      |> Map.put_new("component", %{"const" => name})

    required = List.wrap(schema["required"])
    others = required -- ["id", "component"]
    leading = if v1? and "id" not in required, do: [], else: ["id"]

    schema
    |> Map.put("properties", properties)
    |> Map.put("required", leading ++ others ++ ["component"])
  end

  defp declare_envelope(schema, _name, _v1?, _flattened?), do: schema

  # `allOf` over common-type mixins and plain objects becomes a single
  # `properties` / `required` schema. Anything else in a branch (a
  # conditional, a union) cannot be merged, so the schema is left alone.
  defp flatten(%{"allOf" => branches} = schema, lookup) when is_list(branches) do
    local = Map.merge(lookup, schema["$defs"] || %{})

    case merge_branches(branches, local, %{properties: %{}, required: []}, 0) do
      {:ok, merged} ->
        properties = Map.merge(merged.properties, schema["properties"] || %{})
        required = Enum.uniq(merged.required ++ List.wrap(schema["required"]))

        flat =
          schema
          |> Map.delete("allOf")
          |> Map.put("type", "object")
          |> Map.put("properties", properties)
          |> put_present("required", required)

        {flat, true}

      :error ->
        {schema, false}
    end
  end

  defp flatten(schema, _lookup), do: {schema, false}

  @mergeable_keys ~w(type description title properties required allOf $defs
                     unevaluatedProperties additionalProperties)

  defp merge_branches(_branches, _lookup, _acc, depth) when depth > 8, do: :error

  defp merge_branches(branches, lookup, acc, depth) do
    Enum.reduce_while(branches, {:ok, acc}, fn branch, {:ok, acc} ->
      case merge_branch(branch, lookup, acc, depth) do
        {:ok, acc} -> {:cont, {:ok, acc}}
        :error -> {:halt, :error}
      end
    end)
  end

  defp merge_branch(%{"$ref" => "#/$defs/" <> name}, lookup, acc, depth) do
    case lookup do
      %{^name => %{} = target} -> merge_branch(target, lookup, acc, depth + 1)
      _unknown -> :error
    end
  end

  defp merge_branch(%{} = branch, lookup, acc, depth) do
    if Enum.all?(Map.keys(branch), &(&1 in @mergeable_keys)) do
      with {:ok, acc} <- merge_nested(branch["allOf"], lookup, acc, depth) do
        {:ok,
         %{
           acc
           | properties: Map.merge(acc.properties, branch["properties"] || %{}),
             required: Enum.uniq(acc.required ++ List.wrap(branch["required"]))
         }}
      end
    else
      :error
    end
  end

  defp merge_branch(_other, _lookup, _acc, _depth), do: :error

  defp merge_nested(nil, _lookup, acc, _depth), do: {:ok, acc}

  defp merge_nested(branches, lookup, acc, depth) when is_list(branches),
    do: merge_branches(branches, lookup, acc, depth + 1)

  defp merge_nested(_other, _lookup, _acc, _depth), do: :error

  # -- common types -------------------------------------------------------------

  defp bundle_common_types(schema, version) do
    common = common_definitions(version)
    own = Map.get(schema, "$defs", %{})
    bundled = collect(def_refs(schema), common, own, %{})
    defs = Map.merge(bundled, own)

    defs =
      if needs_function_union?(schema, defs),
        do: Map.put(defs, "anyFunction", %{"not" => %{}}),
        else: defs

    put_present(schema, "$defs", defs)
  end

  defp collect([], _common, _own, chosen), do: chosen

  defp collect([name | rest], common, own, chosen) do
    cond do
      Map.has_key?(own, name) or Map.has_key?(chosen, name) ->
        collect(rest, common, own, chosen)

      Map.has_key?(common, name) ->
        collect(def_refs(common[name]) ++ rest, common, own, Map.put(chosen, name, common[name]))

      true ->
        collect(rest, common, own, chosen)
    end
  end

  defp needs_function_union?(schema, defs) do
    not Map.has_key?(defs, "anyFunction") and
      "anyFunction" in def_refs(Map.put(schema, "$defs", defs))
  end

  @doc """
  The `$defs` of the protocol version's `common_types.json`, with
  cross-document references made local. Empty for an unsupported
  version.
  """
  @spec common_definitions(String.t()) :: map()
  def common_definitions(version) do
    with {:ok, canonical} <- Version.to_protocol_version(version),
         true <- canonical in Version.supported() do
      cached_common_definitions(canonical)
    else
      _ -> %{}
    end
  end

  defp cached_common_definitions(canonical) do
    key = {__MODULE__, :common_definitions, canonical}

    case :persistent_term.get(key, :missing) do
      :missing ->
        defs =
          case Source.document(canonical, :common_types) do
            %{"$defs" => defs} -> localize(defs)
            _other -> %{}
          end

        :persistent_term.put(key, defs)
        defs

      defs ->
        defs
    end
  end

  # The names of the `#/$defs/…` targets referenced anywhere in `node`.
  defp def_refs(node), do: node |> do_def_refs([]) |> Enum.uniq() |> Enum.sort()

  defp do_def_refs(%{} = node, acc) do
    acc =
      case node do
        %{"$ref" => "#/$defs/" <> target} -> [target |> String.split("/") |> hd() | acc]
        _other -> acc
      end

    Enum.reduce(node, acc, fn {_key, value}, acc -> do_def_refs(value, acc) end)
  end

  defp do_def_refs(list, acc) when is_list(list), do: Enum.reduce(list, acc, &do_def_refs/2)
  defp do_def_refs(_other, acc), do: acc

  @doc false
  # Rewrites references into `common_types.json` / `catalog.json` as
  # local `#/$defs/…` pointers.
  @spec localize(term()) :: term()
  def localize(%{} = node) do
    Map.new(node, fn
      {"$ref", ref} when is_binary(ref) -> {"$ref", localize_ref(ref)}
      {key, value} -> {key, localize(value)}
    end)
  end

  def localize(list) when is_list(list), do: Enum.map(list, &localize/1)
  def localize(other), do: other

  defp localize_ref(ref) do
    with true <- String.contains?(ref, "#/$defs/"),
         false <- String.starts_with?(ref, "#/"),
         [document, fragment] <- String.split(ref, "#", parts: 2),
         true <- Enum.any?(@localizable_documents, &String.ends_with?(document, &1)) do
      "#" <> fragment
    else
      _ -> ref
    end
  end

  # -- helpers ------------------------------------------------------------------

  defp present?(value), do: is_binary(value) and value != ""

  defp catalog_error(message), do: Error.new(:catalog, "CATALOG_ERROR", message)

  defp unwrap!({:ok, value}), do: value
  defp unwrap!({:error, error}), do: raise(error)

  defp type_name(value) when is_map(value), do: "object"
  defp type_name(value) when is_list(value), do: "list"
  defp type_name(value) when is_binary(value), do: "str"
  defp type_name(value) when is_integer(value), do: "int"
  defp type_name(value) when is_float(value), do: "float"
  defp type_name(value) when is_boolean(value), do: "bool"
  defp type_name(nil), do: "NoneType"
  defp type_name(_value), do: "object"
end

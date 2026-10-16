defmodule A2UICore.Validation.Payload do
  @moduledoc """
  Validates component, function-call and theme payloads against a
  catalog.

  All three return `:ok` / `{:ok, value}` or
  `{:error, %A2UICore.Error{category: :validation}}` whose `details`
  list every violation as `%{code, path, message}`. Codes follow the
  reference: `missing_field`, `extra_field`, `type_mismatch`,
  `invalid_value`, `unrecognized_component`, `unrecognized_function`,
  `too_many_arguments`, `invalid_identifier`, `invalid_reference`,
  `invalid_function_call`. Paths are `components.<id>.<property path>`
  and `functions.<name>.<argument path>`; the error message joins
  `path: message` lines.

  A component property that fails its schema is reported as
  `missing_field` (required), `extra_field` (surplus) or `invalid_value`
  (anything else — wrong type, value outside an enum, pattern…), which
  is what the shared conformance suites expect. An unknown component
  type carries an `invalid_value` detail at its `component` property next
  to `unrecognized_component`.

  With `allow_unknown_elements` (the relaxed configuration) unknown
  component types, unknown functions and unknown properties are
  tolerated.

  A component is validated against its resolved schema
  (`A2UICore.Catalog.resolved_component_schema/2`) with the validation
  schema's `$defs`. The function calls nested in it are checked on their
  own: a call that runs in this catalog (it names it, or names no
  `catalogId` in a component that names none either) is fully checked;
  a call into another catalog only for well-formed identifiers, since
  the processor checks it against the catalog it resolves to. From v1.0
  a call to a system function (`@index`) belongs to no catalog. Errors of
  a nested call are reported at the call's location
  (`components.<id>.<property>.args.<argument>`).
  """

  alias A2UICore.Catalog
  alias A2UICore.CommonTypes
  alias A2UICore.Error
  alias A2UICore.Error.Detail
  alias A2UICore.{Identifier, Schema}
  alias A2UICore.Validation.{Config, ReservedKeys}

  @moduledoc since: "0.1.0"

  @draft "https://json-schema.org/draft/2020-12/schema"
  @max_function_call_args 1_000
  @envelope_keys ["id", "component"]
  @v1_envelope_keys ["id", "component", "catalogId", "metadata"]

  @system_function_args %{
    "@index" => %{
      "type" => "object",
      "properties" => %{
        "offset" => %{"anyOf" => [%{"$ref" => "#/$defs/DynamicNumber"}, %{"type" => "null"}]}
      },
      "additionalProperties" => false
    }
  }

  @doc """
  The most arguments one function call may carry.
  """
  @spec max_function_call_args() :: pos_integer()
  def max_function_call_args, do: @max_function_call_args

  # -- components ---------------------------------------------------------------

  @doc """
  Validates one component payload against `catalog`.
  """
  @spec validate_component(Catalog.t(), term(), Config.t()) :: :ok | {:error, Error.t()}
  def validate_component(catalog, component, config \\ Config.strict())

  def validate_component(%Catalog{}, component, _config) when not is_map(component) do
    detail = Detail.new("type_mismatch", "Component must be an object", "components")
    {:error, failure("Component must be an object", [detail])}
  end

  def validate_component(%Catalog{} = catalog, component, %Config{} = config) do
    id = component["id"]
    type = component["component"]
    owner = if is_binary(id) and id != "", do: id, else: "unknown"

    identifier_errors = component_identifier_errors(catalog, id)

    nested =
      nested_function_errors(catalog, {owner, component["catalogId"]}, component, "", config)

    case Catalog.get_component(catalog, type) do
      nil ->
        unknown_component(identifier_errors, nested, catalog.catalog_id, id, type, config)

      found ->
        errors =
          identifier_errors ++
            component_schema_errors(catalog, found, component, owner, config) ++ nested

        finish(errors)
    end
  end

  defp component_identifier_errors(catalog, id) when is_binary(id) and id != "" do
    if Catalog.v1?(catalog) and not Identifier.valid?(id) do
      [
        Detail.new(
          "invalid_identifier",
          "Component id '#{id}' must be a valid UAX #31 identifier",
          "components.#{id}.id"
        )
      ]
    else
      []
    end
  end

  defp component_identifier_errors(_catalog, _id), do: []

  defp unknown_component(errors, nested, _catalog_id, _id, _type, %Config{
         allow_unknown_elements: true
       }),
       do: finish(errors ++ nested)

  defp unknown_component(errors, nested, catalog_id, id, type, _config) do
    path = "components.#{display(id)}.component"

    unrecognized =
      Detail.new("unrecognized_component", "Unrecognized component type '#{display(type)}'", path)

    invalid =
      Detail.new(
        "invalid_value",
        "'#{display(type)}' is not a component of catalog '#{catalog_id}'",
        path
      )

    reported = errors ++ [unrecognized] ++ nested
    {:error, failure(summary(reported), errors ++ [unrecognized, invalid] ++ nested)}
  end

  # A function call inside a component is checked for its shape here;
  # whether the function exists, and its arguments, are checked per call
  # (`nested_function_errors/4`) against the catalog the call names. The
  # catalog's own `anyFunction` union would reject a call into another
  # catalog, so a well-formed-call stand-in takes its place.
  defp component_schema_errors(catalog, component, payload, owner, config) do
    schema = Catalog.resolved_component_schema(catalog, component.name) || component.schema
    version = if Catalog.v1?(catalog), do: "v1.0", else: "v0.9"
    common = Catalog.common_definitions(catalog.protocol_version)

    defs =
      (catalog.schema["$defs"] || %{})
      |> put_missing(common, ["ComponentCommon", "Checkable"])
      |> Map.put("anyFunction", CommonTypes.function_stub(version))
      |> Map.merge(schema["$defs"] || %{})

    full =
      schema
      |> Map.delete("$defs")
      |> Map.merge(%{"$schema" => @draft, "$defs" => defs})
      |> with_catalog_sections(catalog.schema)

    {payload, envelope_errors} = strip_undeclared(payload, full, owner, catalog)

    case Schema.validate(payload, full, root: full) do
      :ok ->
        envelope_errors

      {:error, details} ->
        envelope_errors ++
          (details |> Enum.map(&property_code/1) |> prefix_details("components.#{owner}", config))
    end
  end

  defp put_missing(defs, source, names) do
    Enum.reduce(names, defs, fn name, acc ->
      case source do
        %{^name => definition} -> Map.put_new(acc, name, definition)
        _absent -> acc
      end
    end)
  end

  # The engine reports `type`, `enum`, `pattern` and `format` failures as
  # `type_mismatch`; for a component property they are `invalid_value`.
  defp property_code(%Detail{code: "type_mismatch"} = detail),
    do: %{detail | code: "invalid_value"}

  defp property_code(detail), do: detail

  # The envelope keys (`id` and `component`; from v1.0 also `catalogId`
  # and `metadata`) belong to the component message: a schema that does
  # not declare one must not see it. A `catalogId` removed this way must
  # still be a string.
  defp strip_undeclared(payload, schema, owner, catalog) do
    keys = if Catalog.v1?(catalog), do: @v1_envelope_keys, else: @envelope_keys

    Enum.reduce(keys, {payload, []}, fn key, {acc, errors} ->
      cond do
        not Map.has_key?(acc, key) -> {acc, errors}
        declares?(schema, key) or key in List.wrap(schema["required"]) -> {acc, errors}
        true -> {Map.delete(acc, key), errors ++ envelope_type_errors(key, acc[key], owner)}
      end
    end)
  end

  defp envelope_type_errors("catalogId", value, owner) when not is_binary(value),
    do: [
      Detail.new("type_mismatch", "'catalogId' must be a string", "components.#{owner}.catalogId")
    ]

  defp envelope_type_errors(_key, _value, _owner), do: []

  defp declares?(%{"$ref" => _}, _property), do: true

  defp declares?(%{} = schema, property) do
    direct? =
      match?(%{"properties" => %{^property => _}}, schema)

    direct? or
      Enum.any?(["allOf", "anyOf", "oneOf"], fn keyword ->
        case schema[keyword] do
          branches when is_list(branches) -> Enum.any?(branches, &declares?(&1, property))
          _other -> false
        end
      end)
  end

  defp declares?(_schema, _property), do: false

  defp with_catalog_sections(schema, catalog_schema) do
    Enum.reduce(["functions", "components"], schema, fn key, acc ->
      case catalog_schema do
        %{^key => value} -> Map.put_new(acc, key, value)
        _no_section -> acc
      end
    end)
  end

  defp prefix_details(details, prefix, config) do
    for %Detail{} = detail <- details, not tolerated?(detail, config) do
      path = if detail.path in [nil, ""], do: prefix, else: prefix <> "." <> detail.path
      %Detail{detail | path: path}
    end
  end

  defp tolerated?(%Detail{code: "extra_field", message: message}, %Config{
         allow_unknown_elements: true
       }),
       do: not String.contains?(message, "any of the regexes")

  defp tolerated?(_detail, _config), do: false

  # Function calls nested anywhere in a component (see the module doc).
  # `component` is `{owner id, the catalogId the component names}`.
  defp nested_function_errors(catalog, component, %{} = value, path, config) do
    own = call_errors(catalog, component, value, path, config)

    children =
      value
      |> Enum.sort_by(&elem(&1, 0))
      |> Enum.flat_map(fn
        {key, _child} when key in ["id", "component"] -> []
        {key, child} -> nested_function_errors(catalog, component, child, join(path, key), config)
      end)

    own ++ children
  end

  defp nested_function_errors(catalog, component, list, path, config) when is_list(list) do
    list
    |> Enum.with_index()
    |> Enum.flat_map(fn {item, index} ->
      nested_function_errors(catalog, component, item, join(path, index), config)
    end)
  end

  defp nested_function_errors(_catalog, _component, _value, _path, _config), do: []

  defp call_errors(catalog, {owner, _component_catalog} = component, value, path, config) do
    v1? = Catalog.v1?(catalog)
    location = if path == "", do: "components.#{owner}", else: "components.#{owner}.#{path}"
    reserved = if v1?, do: reserved_key_errors(catalog, value, location), else: []
    name = if v1?, do: value["@call"], else: value["call"] || value["function"]

    # From v1.0 any string name is checked, so an empty one is reported as
    # an invalid identifier rather than skipped.
    if is_binary(name) and (v1? or name != ""),
      do: reserved ++ nested_call_errors(catalog, component, name, value, location, config),
      else: reserved
  end

  defp reserved_key_errors(catalog, value, location) do
    case ReservedKeys.check(Map.keys(value), catalog.protocol_version) do
      :ok -> []
      {:error, error} -> [Detail.new(error.code, error.message, location)]
    end
  end

  defp nested_call_errors(catalog, {_owner, component_catalog}, name, value, location, config) do
    cond do
      Catalog.v1?(catalog) and String.starts_with?(name, "@") ->
        system_call_errors(catalog, name, value, location, config)

      not Catalog.v1?(catalog) ->
        rebase(
          validate_function(catalog, name, value["args"], config),
          name,
          location,
          "invalid_function_call"
        )

      Map.has_key?(value, "catalogId") and not is_binary(value["catalogId"]) ->
        [Detail.new("type_mismatch", "'catalogId' must be a string", location <> ".catalogId")] ++
          rebase(
            check_identifiers(catalog, name, value["args"]),
            name,
            location,
            "invalid_identifier"
          )

      runs_here?(value["catalogId"], catalog.catalog_id, component_catalog) ->
        rebase(
          validate_function(catalog, name, value["args"], config),
          name,
          location,
          "invalid_function_call"
        )

      true ->
        rebase(
          check_identifiers(catalog, name, value["args"]),
          name,
          location,
          "invalid_identifier"
        )
    end
  end

  # A call runs in the catalog it names, or else in the surface default;
  # a component that names no catalog is taken to be in the default.
  defp runs_here?(nil, _catalog_id, component_catalog), do: is_nil(component_catalog)
  defp runs_here?(call_catalog, catalog_id, _component_catalog), do: call_catalog == catalog_id

  defp system_call_errors(catalog, name, value, location, config) do
    catalog_errors =
      if Map.has_key?(value, "catalogId") do
        [
          Detail.new(
            "extra_field",
            "System function '#{name}' belongs to no catalog and must not name a catalogId",
            location <> ".catalogId"
          )
        ]
      else
        []
      end

    catalog_errors ++
      rebase(
        validate_system_function(name, value["args"], catalog.protocol_version, config),
        name,
        location,
        "invalid_function_call"
      )
  end

  @doc """
  Validates a call to a system function (`@index` from v1.0) of
  `version`, which belongs to no catalog.
  """
  @spec validate_system_function(String.t(), term(), String.t(), Config.t()) ::
          {:ok, map()} | {:error, Error.t()}
  def validate_system_function(name, args, version, config \\ Config.strict()) do
    # A catalog without functions: the lookup falls through to the system
    # functions of the version.
    validate_function(%Catalog{catalog_id: "", protocol_version: version}, name, args, config)
  end

  @doc """
  Moves the details of a function call's error from `functions.<name>…`
  to the call's location in a component (`location`, such as
  `components.t1.text`): `functions.<name>` becomes `location` and
  `functions.<name>.<argument>…` becomes `location.args.<argument>…`.
  An error without details gets one with `code`. Returns `[]` for a
  successful result.
  """
  @spec rebase(:ok | {:ok, term()} | {:error, Error.t()}, String.t(), String.t(), String.t()) ::
          [Detail.t()]
  def rebase(result, name, location, code \\ "invalid_function_call")
  def rebase(:ok, _name, _location, _code), do: []
  def rebase({:ok, _args}, _name, _location, _code), do: []

  def rebase({:error, %Error{details: details, message: message}}, name, location, code) do
    prefix = "functions.#{name}"
    details = if details in [nil, []], do: [Detail.new(code, message, prefix)], else: details

    Enum.map(details, fn %Detail{path: path} = detail ->
      cond do
        path == prefix ->
          %{detail | path: location}

        String.starts_with?(path || "", prefix <> ".") ->
          %{detail | path: location <> ".args" <> String.replace_prefix(path, prefix, "")}

        true ->
          %{detail | path: "#{location}.#{path}"}
      end
    end)
  end

  # -- functions ----------------------------------------------------------------

  @doc """
  Validates the arguments of a call to `name` against the catalog's
  declaration, returning them with schema defaults filled in.
  """
  @spec validate_function(Catalog.t(), String.t(), term(), Config.t()) ::
          {:ok, map()} | {:error, Error.t()}
  def validate_function(catalog, name, args, config \\ Config.strict())

  def validate_function(%Catalog{} = catalog, name, args, %Config{} = config) do
    with {:ok, arguments} <- normalize_arguments(name, args),
         :ok <- check_argument_count(name, arguments),
         :ok <- check_identifiers(catalog, name, arguments) do
      case find_function(catalog, name) do
        nil -> unknown_function(name, arguments, config)
        schema -> validate_arguments(catalog, schema, name, arguments, config)
      end
    end
  end

  defp normalize_arguments(_name, nil), do: {:ok, %{}}
  defp normalize_arguments(_name, args) when is_map(args), do: {:ok, args}

  defp normalize_arguments(name, _args) do
    message = "Function arguments for '#{name}' must be an object/dictionary"
    detail = Detail.new("type_mismatch", message, "functions.#{name}")
    {:error, failure(message, [detail])}
  end

  defp check_argument_count(name, arguments) do
    if map_size(arguments) > @max_function_call_args do
      message =
        "Function call '#{name}' exceeds maximum allowed arguments count " <>
          "(#{@max_function_call_args})"

      {:error, failure(message, [Detail.new("too_many_arguments", message, "functions.#{name}")])}
    else
      :ok
    end
  end

  defp check_identifiers(%Catalog{} = catalog, name, args) do
    if Catalog.v1?(catalog) do
      with :ok <- check_function_name(name) do
        check_argument_names(name, args)
      end
    else
      :ok
    end
  end

  defp check_function_name(name) do
    if Identifier.valid?(name, allow_leading_at: true) do
      :ok
    else
      message = "Function name '#{name}' must be a valid UAX #31 identifier"
      {:error, failure(message, [Detail.new("invalid_identifier", message, "functions.#{name}")])}
    end
  end

  defp check_argument_names(name, args) when is_map(args) do
    case args |> Map.keys() |> Enum.sort() |> Enum.find(&(not Identifier.valid?(&1))) do
      nil ->
        :ok

      argument ->
        message =
          "Function argument '#{argument}' in function '#{name}' must be a valid UAX #31 identifier"

        detail = Detail.new("invalid_identifier", message, "functions.#{name}.#{argument}")
        {:error, failure(message, [detail])}
    end
  end

  defp check_argument_names(_name, _args), do: :ok

  defp unknown_function(name, arguments, config) do
    if config.allow_unknown_elements do
      {:ok, arguments}
    else
      message = "Unrecognized function '#{name}'"

      {:error,
       failure(message, [Detail.new("unrecognized_function", message, "functions.#{name}")])}
    end
  end

  # The declaration schema of `name`, or `nil`. System functions
  # (`@index`) belong to every catalog of a version that defines them.
  defp find_function(%Catalog{} = catalog, name) do
    case Catalog.get_function(catalog, name) do
      %{name: declared, schema: schema} when is_map(schema) ->
        {:declared, Catalog.resolved_function_schema(catalog, declared) || schema}

      nil ->
        system_function(catalog, name)
    end
  end

  defp system_function(catalog, name) do
    if Catalog.v1?(catalog), do: Map.get(@system_function_args, name)
  end

  defp validate_arguments(catalog, {:declared, schema}, name, arguments, config) do
    defs = Map.merge(catalog.schema["$defs"] || %{}, schema["$defs"] || %{})

    case parameter_schema(schema, defs) do
      nil -> {:ok, arguments}
      parameters -> run_parameters(catalog, parameters, name, arguments, config)
    end
  end

  defp validate_arguments(catalog, %{} = args_schema, name, arguments, config) do
    defs = Catalog.common_definitions(catalog.protocol_version)
    defs = Map.merge(defs, catalog.schema["$defs"] || %{})
    parameters = Map.merge(args_schema, %{"$schema" => @draft, "$defs" => defs})
    run_parameters(catalog, parameters, name, arguments, config)
  end

  defp run_parameters(catalog, parameters, name, arguments, config) do
    parameters = with_catalog_sections(parameters, catalog.schema)

    case Schema.validate(arguments, parameters, root: parameters) do
      :ok ->
        {:ok, fill_defaults(arguments, parameters)}

      {:error, details} ->
        case prefix_details(details, "functions.#{name}", config) do
          [] -> {:ok, fill_defaults(arguments, parameters)}
          kept -> {:error, failure(summary(kept), kept)}
        end
    end
  end

  # The schema of the arguments: the legacy `parameters` map, the
  # `properties.args` of a call schema, or the declaration itself.
  defp parameter_schema(%{"parameters" => parameters} = schema, defs) when is_map(parameters) do
    base = %{"$schema" => @draft, "$defs" => defs, "type" => "object", "properties" => parameters}

    Enum.reduce(["required", "additionalProperties"], base, fn key, acc ->
      case schema do
        %{^key => value} -> Map.put(acc, key, value)
        _absent -> acc
      end
    end)
  end

  defp parameter_schema(%{"properties" => %{"args" => args}}, defs) when is_map(args),
    do: Map.merge(%{"$schema" => @draft, "$defs" => defs}, args)

  defp parameter_schema(%{"properties" => properties} = schema, defs) when is_map(properties),
    do: Map.merge(%{"$schema" => @draft, "$defs" => defs, "type" => "object"}, schema)

  defp parameter_schema(_schema, _defs), do: nil

  defp fill_defaults(arguments, %{"properties" => properties}) when is_map(properties) do
    Enum.reduce(properties, arguments, fn
      {name, %{"default" => default}}, acc -> Map.put_new(acc, name, default)
      {_name, _spec}, acc -> acc
    end)
  end

  defp fill_defaults(arguments, _parameters), do: arguments

  # -- theme --------------------------------------------------------------------

  @doc """
  Validates a theme object against the catalog's theme schema. A
  catalog without one accepts any object.
  """
  @spec validate_theme(Catalog.t(), term()) :: :ok | {:error, Error.t()}
  def validate_theme(%Catalog{}, theme) when not is_map(theme) do
    message = "Theme payload must be an object"
    {:error, failure(message, [Detail.new("type_mismatch", message, "theme")])}
  end

  def validate_theme(%Catalog{theme: theme}, _payload) when map_size(theme) == 0, do: :ok

  def validate_theme(%Catalog{} = catalog, payload) do
    full =
      catalog
      |> Catalog.resolved_theme_schema()
      |> Map.merge(%{"$schema" => @draft, "$defs" => catalog.schema["$defs"] || %{}})
      |> with_catalog_sections(catalog.schema)

    case Schema.validate(payload, full, root: full) do
      :ok ->
        :ok

      {:error, details} ->
        details =
          for %Detail{} = detail <- details, do: %Detail{detail | path: theme_path(detail.path)}

        {:error, failure(summary(details), details)}
    end
  end

  defp theme_path(path) when path in [nil, ""], do: "theme"
  defp theme_path(path), do: path

  # -- helpers ------------------------------------------------------------------

  defp finish([]), do: :ok
  defp finish(errors), do: {:error, failure(summary(errors), errors)}

  defp summary(details), do: Enum.map_join(details, "\n", &"#{&1.path}: #{&1.message}")

  defp failure(message, details),
    do: Error.new(:validation, "VALIDATION_FAILED", message, details: details)

  defp join("", key), do: to_string(key)
  defp join(path, key), do: "#{path}.#{key}"

  defp display(nil), do: "None"
  defp display(value), do: to_string(value)
end

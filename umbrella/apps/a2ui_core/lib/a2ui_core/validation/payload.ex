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

    case Catalog.get_component(catalog, type) do
      nil ->
        unknown_component(identifier_errors, catalog.catalog_id, id, type, config)

      found ->
        errors =
          identifier_errors ++
            component_schema_errors(catalog, found, component, owner, config) ++
            nested_function_errors(catalog, owner, component, "")

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

  defp unknown_component(errors, _catalog_id, _id, _type, %Config{allow_unknown_elements: true}),
    do: finish(errors)

  defp unknown_component(errors, catalog_id, id, type, _config) do
    path = "components.#{display(id)}.component"

    unrecognized =
      Detail.new("unrecognized_component", "Unrecognized component type '#{display(type)}'", path)

    invalid =
      Detail.new(
        "invalid_value",
        "'#{display(type)}' is not a component of catalog '#{catalog_id}'",
        path
      )

    {:error, failure(summary(errors ++ [unrecognized]), errors ++ [unrecognized, invalid])}
  end

  # A function call inside a component is checked for its shape here;
  # whether the function exists, and its arguments, are checked per call
  # (`nested_function_errors/4`) against the catalog the call names. The
  # catalog's own `anyFunction` union would reject a call into another
  # catalog, so a well-formed-call stand-in takes its place.
  defp component_schema_errors(catalog, component, payload, owner, config) do
    schema = component.schema
    version = if Catalog.v1?(catalog), do: "v1.0", else: "v0.9"

    defs =
      (catalog.schema["$defs"] || %{})
      |> Map.put("anyFunction", CommonTypes.function_stub(version))
      |> Map.merge(schema["$defs"] || %{})

    full =
      schema
      |> Map.delete("$defs")
      |> Map.merge(%{"$schema" => @draft, "$defs" => defs})
      |> with_catalog_sections(catalog.schema)

    payload
    |> strip_undeclared(full)
    |> Schema.validate(full, root: full)
    |> case do
      :ok ->
        []

      {:error, details} ->
        details |> Enum.map(&property_code/1) |> prefix_details("components.#{owner}", config)
    end
  end

  # The engine reports `type`, `enum`, `pattern` and `format` failures as
  # `type_mismatch`; for a component property they are `invalid_value`.
  defp property_code(%Detail{code: "type_mismatch"} = detail),
    do: %{detail | code: "invalid_value"}

  defp property_code(detail), do: detail

  # `id` and `component` belong to the envelope: a schema that does not
  # declare them must not see them.
  defp strip_undeclared(payload, schema) do
    Enum.reduce(["id", "component"], payload, fn property, acc ->
      if declares?(schema, property) or property in List.wrap(schema["required"]) do
        acc
      else
        Map.delete(acc, property)
      end
    end)
  end

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

  # Function calls nested anywhere in a component are validated against
  # the catalog that declares them; a call naming another catalog is
  # only checked for well-formed identifiers.
  defp nested_function_errors(catalog, owner, %{} = value, path) do
    own = call_errors(catalog, owner, value, path)

    children =
      value
      |> Enum.sort_by(&elem(&1, 0))
      |> Enum.flat_map(fn
        {key, _child} when key in ["id", "component"] -> []
        {key, child} -> nested_function_errors(catalog, owner, child, join(path, key))
      end)

    own ++ children
  end

  defp nested_function_errors(catalog, owner, list, path) when is_list(list) do
    list
    |> Enum.with_index()
    |> Enum.flat_map(fn {item, index} ->
      nested_function_errors(catalog, owner, item, join(path, index))
    end)
  end

  defp nested_function_errors(_catalog, _owner, _value, _path), do: []

  defp call_errors(catalog, owner, value, path) do
    v1? = Catalog.v1?(catalog)
    location = if path == "", do: "components.#{owner}", else: "components.#{owner}.#{path}"

    reserved =
      if v1? do
        case ReservedKeys.check(Map.keys(value), catalog.protocol_version) do
          :ok -> []
          {:error, error} -> [Detail.new(error.code, error.message, location)]
        end
      else
        []
      end

    name = if v1?, do: value["@call"], else: value["call"] || value["function"]
    reserved ++ call_name_errors(catalog, name, value, location)
  end

  defp call_name_errors(catalog, name, value, location) when is_binary(name) and name != "" do
    catalog_id = value["catalogId"]
    own? = catalog_id in [nil, "", catalog.catalog_id]

    result =
      if own?,
        do: validate_function(catalog, name, value["args"]),
        else: check_identifiers(catalog, name, value["args"])

    case result do
      {:error, %Error{details: [_ | _] = details}} ->
        details

      {:error, %Error{message: message}} ->
        code = if own?, do: "invalid_function_call", else: "invalid_identifier"
        [Detail.new(code, message, location)]

      _ok ->
        []
    end
  end

  defp call_name_errors(_catalog, _name, _value, _location), do: []

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
    if Identifier.valid?(name) do
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
      %{schema: schema} when is_map(schema) -> {:declared, schema}
      nil -> system_function(catalog, name)
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

  def validate_theme(%Catalog{theme: theme} = catalog, payload) do
    full =
      theme
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

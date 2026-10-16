defmodule A2UICore.Catalog.Function do
  @moduledoc """
  A function a catalog declares: its schema plus, when the catalog can
  evaluate it, an implementation.

    * `:name` — the name a call uses (`formatString`, `@index`).
    * `:schema` — the function's definition as the catalog document
      writes it (a call schema with `call`/`@call` and `args`), or, for
      a function defined in code, possibly just the schema of its
      `args`.
    * `:return_type` — `"string"`, `"number"`, `"boolean"`, `"object"`,
      `"array"`, `"any"` or `"void"`, when declared (a top-level
      `returnType`, or the `returnType` constant of a v0.9 call schema);
      `nil` means `"any"`.
    * `:allowed_callers` — `"rendererOnly"`, `"agentOnly"` or
      `"rendererOrAgent"`; `nil` when the catalog omits it, which the
      protocol defines as `"rendererOnly"` (v1.0).
    * `:requires_user_activation` — v1.0.
    * `:description` — the definition's `description`.
    * `:is_definition` — whether `:schema` is the whole catalog entry;
      `nil` infers it from the schema's shape.
    * `:from_document` — whether the schema was read from a catalog
      document (see `A2UICore.Catalog.Component`).
    * `:execute` — `nil` for a schema-only function, else a function of
      `(args, context)` returning `{:ok, value}`, `{:ok, value, effects}`
      or `{:error, A2UICore.Error.t()}`. `args` are already resolved;
      `context` is the `A2UICore.Resolution.DataContext` of the call.
  """

  @moduledoc since: "0.1.0"

  @enforce_keys [:name]
  defstruct [
    :name,
    :return_type,
    :allowed_callers,
    :requires_user_activation,
    :description,
    :is_definition,
    :execute,
    schema: %{},
    from_document: false
  ]

  @type effects :: [A2UICore.Resolution.DataContext.effect()]

  @type execute ::
          (map(), A2UICore.Resolution.DataContext.t() | nil ->
             {:ok, term()} | {:ok, term(), effects()} | {:error, A2UICore.Error.t()})

  @type t :: %__MODULE__{
          name: String.t(),
          schema: map(),
          return_type: String.t() | nil,
          allowed_callers: String.t() | nil,
          requires_user_activation: boolean() | nil,
          description: String.t() | nil,
          is_definition: boolean() | nil,
          from_document: boolean(),
          execute: execute() | nil
        }

  @definition_keywords ["returnType", "parameters", "allowedCallers", "requiresUserActivation"]

  @doc """
  Builds a function from a catalog document entry (`schema` is the
  function's schema object).

  Options: `:execute`, and `from_document: true` for an entry read from
  a document (which is then also a definition).
  """
  @spec from_schema(String.t(), map(), execute() | nil | keyword()) :: t()
  def from_schema(name, schema, options \\ [])

  def from_schema(name, schema, execute) when is_function(execute) or is_nil(execute),
    do: from_schema(name, schema, execute: execute)

  def from_schema(name, schema, options) when is_binary(name) and is_map(schema) do
    from_document = Keyword.get(options, :from_document, false)

    %__MODULE__{
      name: name,
      schema: schema,
      return_type: declared_return_type(schema),
      allowed_callers: schema["allowedCallers"],
      requires_user_activation: schema["requiresUserActivation"],
      description: if(is_binary(schema["description"]), do: schema["description"]),
      is_definition: if(from_document, do: true),
      from_document: from_document,
      execute: options[:execute]
    }
  end

  @doc """
  The return type a catalog entry declares, or `nil`: a top-level
  `returnType` (v1.0 and the v0.9 list form) or the `const` of the
  call's `returnType` property (the v0.9 map form).
  """
  @spec declared_return_type(map()) :: term()
  def declared_return_type(%{"returnType" => type}), do: type

  def declared_return_type(%{"properties" => %{"returnType" => %{"const" => type}}})
      when is_binary(type),
      do: type

  def declared_return_type(_schema), do: nil

  @doc """
  Whether the function's schema is its whole catalog entry rather than
  the schema of its `args`: `:is_definition` when set, else a call
  schema (`properties` naming `call`, `@call` or `args`) or one that
  declares a keyword only entries write (`returnType`, …).
  """
  @spec definition?(t()) :: boolean()
  def definition?(%__MODULE__{is_definition: flag, schema: schema}) when is_boolean(flag),
    do: flag and is_map(schema)

  def definition?(%__MODULE__{schema: %{} = schema}) do
    case schema["properties"] do
      %{} = properties when is_map_key(properties, "call") or is_map_key(properties, "@call") ->
        true

      %{"args" => _} ->
        true

      _other ->
        Enum.any?(@definition_keywords, &Map.has_key?(schema, &1))
    end
  end

  def definition?(%__MODULE__{}), do: false

  @doc """
  Attaches an implementation.
  """
  @spec with_execute(t(), execute()) :: t()
  def with_execute(%__MODULE__{} = function, execute) when is_function(execute, 2),
    do: %{function | execute: execute}
end

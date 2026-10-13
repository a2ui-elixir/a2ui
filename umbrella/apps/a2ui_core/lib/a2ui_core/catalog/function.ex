defmodule A2UICore.Catalog.Function do
  @moduledoc """
  A function a catalog declares: its call schema plus, when the catalog
  can evaluate it, an implementation.

    * `:name` — the name a call uses (`formatString`, `@index`).
    * `:schema` — the JSON Schema of a whole call (`call`/`@call`,
      `args`, `returnType`), as written in the catalog document.
    * `:return_type` — `"string"`, `"number"`, `"boolean"`, `"object"`,
      `"array"`, `"any"` or `"void"`, when declared.
    * `:allowed_callers` — `"rendererOnly"`, `"agentOnly"` or
      `"rendererOrAgent"`; `nil` when the catalog omits it, which the
      protocol defines as `"rendererOnly"` (v1.0).
    * `:requires_user_activation` — v1.0.
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
    :execute,
    schema: %{}
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
          execute: execute() | nil
        }

  @doc """
  Builds a function from a catalog document entry (`schema` is the
  function's schema object).
  """
  @spec from_schema(String.t(), map(), execute() | nil) :: t()
  def from_schema(name, schema, execute \\ nil) when is_binary(name) and is_map(schema) do
    %__MODULE__{
      name: name,
      schema: schema,
      return_type: schema["returnType"],
      allowed_callers: schema["allowedCallers"],
      requires_user_activation: schema["requiresUserActivation"],
      execute: execute
    }
  end

  @doc """
  Attaches an implementation.
  """
  @spec with_execute(t(), execute()) :: t()
  def with_execute(%__MODULE__{} = function, execute) when is_function(execute, 2),
    do: %{function | execute: execute}
end

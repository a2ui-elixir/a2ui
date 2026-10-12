defmodule A2UICore.Error do
  @moduledoc """
  The single error struct used across the A2UI packages.

  *Categories* classify errors for conformance matching and are drawn from
  the reference implementation's exception classes:

  | Category | Reference class |
  |---|---|
  | `:parse` | `A2uiParseError` |
  | `:validation` | `A2uiValidationError` |
  | `:catalog` | `A2uiCatalogError` |
  | `:state` | `A2uiStateError` |
  | `:integrity` | `A2uiIntegrityError` |
  | `:recursion` | `A2uiRecursionError` |
  | `:data` | `A2uiDataError` |
  | `:expression` | `A2uiExpressionError` |
  | `:rpc` | `A2uiRpcError` |
  | `:compilation` | `A2uiCompilationError` (agent side) |

  `A2UICore.Error` is usable both as a raised exception and inside
  `{:error, error}` tuples; both forms are equivalent and the harness
  decides which shape is used at the call site.
  """

  @moduledoc since: "0.1.0"

  @type category ::
          :parse
          | :validation
          | :catalog
          | :state
          | :integrity
          | :recursion
          | :data
          | :expression
          | :rpc
          | :compilation

  @type t :: %__MODULE__{
          category: category(),
          code: String.t(),
          message: String.t(),
          path: String.t() | nil,
          surface_id: String.t() | nil,
          function_call_id: String.t() | nil,
          details: [A2UICore.Error.Detail.t()]
        }

  @type detail :: %{path: String.t() | nil, code: String.t(), message: String.t()}

  defexception category: :validation,
               code: "UNKNOWN_ERROR",
               message: "",
               path: nil,
               surface_id: nil,
               function_call_id: nil,
               details: []

  defmodule Detail do
    @moduledoc """
    A single structured diagnostic entry attached to an `A2UICore.Error`.
    """

    @moduledoc since: "0.1.0"

    @enforce_keys [:code, :message]
    defstruct code: nil, path: nil, message: nil

    @type t :: %__MODULE__{code: String.t(), path: String.t() | nil, message: String.t()}

    @doc false
    @spec new(String.t(), String.t(), String.t() | nil) :: t()
    def new(code, message, path \\ nil),
      do: %__MODULE__{code: code, message: message, path: path}

    @doc false
    @spec from_map(map()) :: t()
    def from_map(map) when is_map(map) do
      %__MODULE__{
        code: Map.get(map, :code) || Map.get(map, "code"),
        message: Map.get(map, :message) || Map.get(map, "message"),
        path: Map.get(map, :path) || Map.get(map, "path")
      }
    end
  end

  @doc """
  Builds a new `A2UICore.Error` with the given `category` and `code`.

  ## Options

  - `:path` — JSON pointer of the offending field.
  - `:surface_id` — the surface the error pertains to.
  - `:function_call_id` — relevant for v1.0 RPC failures.
  - `:details` — list of `t:A2UICore.Error.Detail.t/0`.

  ## Examples

      iex> err = A2UICore.Error.new(:validation, "VALIDATION_FAILED", "bad")
      iex> {err.category, err.code}
      {:validation, "VALIDATION_FAILED"}
  """
  @spec new(category(), String.t(), String.t(), keyword()) :: t()
  def new(category, code, message, opts \\ []) when is_atom(category) and is_binary(code) do
    %__MODULE__{
      category: category,
      code: code,
      message: message,
      path: Keyword.get(opts, :path),
      surface_id: Keyword.get(opts, :surface_id),
      function_call_id: Keyword.get(opts, :function_call_id),
      details: Keyword.get(opts, :details, [])
    }
  end

  @doc """
  Convenience raise helper — equivalent to
  `raise A2UICore.Error, category:..., code:..., message:...`.
  """
  @spec raise!(category(), String.t(), String.t(), keyword()) :: no_return()
  @spec raise!(category(), String.t(), String.t()) :: no_return()
  def raise!(category, code, message, opts \\ []) do
    raise __MODULE__,
      category: category,
      code: code,
      message: message,
      path: Keyword.get(opts, :path),
      surface_id: Keyword.get(opts, :surface_id),
      function_call_id: Keyword.get(opts, :function_call_id),
      details: Keyword.get(opts, :details, [])
  end
end

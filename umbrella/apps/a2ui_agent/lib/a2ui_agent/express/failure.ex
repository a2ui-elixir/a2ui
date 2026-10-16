defmodule A2UIAgent.Express.Failure do
  @moduledoc false

  # Raised inside the Express compiler and decompiler, and turned into an
  # `A2UICore.Error` where they return. `kind` is `:parse` for a block
  # the grammar or the format's own rules reject, and `:validation` for
  # one the catalogs refuse.

  alias A2UICore.Error

  defexception kind: :validation, message: "", help: nil, line: nil, column: nil

  @type t :: %__MODULE__{
          kind: :parse | :validation,
          message: String.t(),
          help: String.t() | nil,
          line: pos_integer() | nil,
          column: non_neg_integer() | nil
        }

  @default_help "Please correct the syntax error in your Express DSL."

  @spec parse!(String.t()) :: no_return()
  @spec parse!(String.t(), keyword()) :: no_return()
  def parse!(message, options \\ []), do: raise(new(:parse, message, options))

  @spec validation!(String.t()) :: no_return()
  @spec validation!(String.t(), keyword()) :: no_return()
  def validation!(message, options \\ []), do: raise(new(:validation, message, options))

  defp new(kind, message, options),
    do: %__MODULE__{
      kind: kind,
      message: message,
      help: options[:help],
      line: options[:line],
      column: options[:column]
    }

  @doc false
  # The error a compilation failure is reported as: the message, the
  # line and column when known, and the help text.
  @spec to_compilation_error(t()) :: Error.t()
  def to_compilation_error(%__MODULE__{} = failure) do
    location =
      case failure do
        %{line: nil} -> []
        %{line: line, column: column} -> ["Line #{line}, Col #{column}"]
      end

    message =
      Enum.join([failure.message | location] ++ ["Help: #{failure.help || @default_help}"], " - ")

    to_error(%{failure | message: message})
  end

  @doc false
  @spec to_error(t()) :: Error.t()
  def to_error(%__MODULE__{kind: :parse, message: message}),
    do: Error.new(:parse, "PARSE_ERROR", message)

  def to_error(%__MODULE__{kind: :validation, message: message}),
    do: Error.new(:validation, "VALIDATION_FAILED", message)
end

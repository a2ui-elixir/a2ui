defmodule A2UICore.Functions.System do
  @moduledoc """
  Functions the runtime supplies to every catalog: the `@` namespace.

  v1.0 defines `@index`, which evaluates to the iteration index of the
  collection template being rendered (plus an optional `offset`).
  Catalogs need not declare these; `A2UICore.Catalog.Basic` registers
  them so a catalog can evaluate them.
  """

  alias A2UICore.Catalog.Function
  alias A2UICore.Coerce
  alias A2UICore.Error
  alias A2UICore.Resolution.DataContext
  alias A2UICore.SemVer

  @moduledoc since: "0.1.0"

  @index_schema %{
    "type" => "object",
    "description" =>
      "Evaluates the 0-based iteration index of the collection item being rendered, " <>
        "with an optional offset.",
    "returnType" => "number",
    "allowedCallers" => "rendererOnly",
    "properties" => %{
      "@call" => %{"const" => "@index"},
      "args" => %{
        "type" => "object",
        "properties" => %{
          "offset" => %{
            "anyOf" => [%{"$ref" => "#/$defs/DynamicNumber"}, %{"type" => "null"}],
            "description" =>
              "Optional. An offset to add to the 0-based index (e.g., 1 for 1-based indexing). " <>
                "Defaults to 0."
          }
        },
        "additionalProperties" => false
      }
    },
    "required" => ["@call"]
  }

  @doc """
  The system functions available to a protocol version (none before
  v1.0).
  """
  @spec functions(String.t()) :: [Function.t()]
  def functions(version) do
    if SemVer.at_least(version, "v1.0") do
      [Function.from_schema("@index", @index_schema, &index/2)]
    else
      []
    end
  end

  @doc """
  Evaluates `@index`. Outside a collection scope with a context it is a
  validation error; without any context it is just the offset.
  """
  @spec index(map(), DataContext.t() | nil) :: {:ok, integer()} | {:error, Error.t()}
  def index(args, context) do
    offset = Map.get(args, "offset")

    with {:ok, offset} <- offset_value(offset) do
      case context do
        nil -> {:ok, offset}
        %DataContext{} -> scoped_index(DataContext.index(context), offset)
      end
    end
  end

  defp offset_value(nil), do: {:ok, 0}

  defp offset_value(value) do
    case Coerce.to_integer(value) do
      {:ok, integer} -> {:ok, integer}
      :error -> {:error, validation("@index requires a numeric offset, got #{inspect(value)}.")}
    end
  end

  defp scoped_index(nil, _offset) do
    {:error,
     validation(
       "@index function can only be evaluated inside a collection template iteration scope."
     )}
  end

  defp scoped_index(index, offset), do: {:ok, index + offset}

  defp validation(message), do: Error.new(:validation, "VALIDATION_FAILED", message)
end

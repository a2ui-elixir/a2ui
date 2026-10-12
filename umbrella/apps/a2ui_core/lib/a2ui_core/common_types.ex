defmodule A2UICore.CommonTypes do
  @moduledoc """
  Validates values against the protocol's shared type definitions — the
  `$defs` of each version's `common_types.json` (`DynamicValue`,
  `FunctionCall`, `ChildList`, `Action`, v1.0 `Extensions`, …).

  Validation is catalog-agnostic. `FunctionCall` refers to the active
  catalog's functions (`catalog.json#/$defs/anyFunction`), so the
  catalog slot is bound to a generic stub that accepts any well-formed
  call: in v1.0 an object with a string `@call` (other than the reserved
  `"@index"`, which `IndexSystemFunction` owns) and an optional `args`
  object; in v0.9.x an object of `call`, `args` and `returnType` only.
  Catalog-specific checks (does the function exist, are its arguments
  right) belong to catalog validation.

      iex> A2UICore.CommonTypes.validate(%{"path" => "/user/name"}, "DynamicValue", "v0.9.1")
      {:ok, %{"path" => "/user/name"}}

      iex> {:error, error} = A2UICore.CommonTypes.validate(%{"1st" => 1}, "Extensions", "v1.0")
      iex> error.category
      :validation
  """

  alias A2UICore.Error
  alias A2UICore.Schema
  alias A2UICore.Schema.Source
  alias A2UICore.Version

  @moduledoc since: "0.1.0"

  @v1_0_function_stub %{
    "type" => "object",
    "properties" => %{
      "@call" => %{"type" => "string", "not" => %{"const" => "@index"}},
      "args" => %{"type" => "object"}
    },
    "required" => ["@call"]
  }

  # The field types themselves are constrained by common_types.json's
  # FunctionCall; the stub only closes the object.
  @v0_9_function_stub %{
    "type" => "object",
    "properties" => %{"call" => true, "args" => true, "returnType" => true},
    "additionalProperties" => false
  }

  @doc """
  The definition names `version`'s `common_types.json` declares.
  """
  @spec definitions(Version.protocol_version()) :: [String.t()]
  def definitions(version) do
    version |> common_types!() |> Map.get("$defs", %{}) |> Map.keys() |> Enum.sort()
  end

  @doc """
  Validates `value` as the common type `definition` of protocol
  `version`.

  Returns `{:ok, value}` (the value unchanged — common types carry no
  defaults to fill in) or `{:error, %A2UICore.Error{category: :validation}}`
  with one detail per violation. Raises `ArgumentError` for a definition
  the version does not declare.
  """
  @spec validate(term(), String.t(), Version.protocol_version()) ::
          {:ok, term()} | {:error, Error.t()}
  def validate(value, definition, version) when is_binary(definition) do
    common_types = common_types!(version)

    unless Map.has_key?(common_types["$defs"] || %{}, definition) do
      raise ArgumentError,
            "#{inspect(definition)} is not a common types definition in #{version}; " <>
              "known: #{Enum.join(definitions(version), ", ")}"
    end

    schema = %{"$ref" => "common_types.json#/$defs/#{definition}"}

    registry = %{
      "common_types.json" => common_types,
      "catalog.json" => %{"$defs" => %{"anyFunction" => function_stub(version)}}
    }

    case Schema.validate(value, schema, registry: registry, root: common_types) do
      :ok ->
        {:ok, value}

      {:error, details} ->
        {:error,
         Error.new(
           :validation,
           "VALIDATION_FAILED",
           "Value is not a valid #{definition}: #{hd(details).message}",
           details: details
         )}
    end
  end

  defp common_types!(version) do
    case Source.document(version, :common_types) do
      nil -> raise ArgumentError, "no common types for protocol version #{inspect(version)}"
      document -> document
    end
  end

  defp function_stub("v1.0"), do: @v1_0_function_stub
  defp function_stub(_v0_9), do: @v0_9_function_stub
end

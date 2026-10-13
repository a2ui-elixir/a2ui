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

  @doc """
  The names of the dynamic-value definitions across protocol versions
  (`DynamicString`, `DynamicValue`, …): unions that accept a `DataBinding`,
  a `FunctionCall` and literal values. `DataBinding` itself is included.
  """
  @spec dynamic_definitions() :: MapSet.t(String.t())
  def dynamic_definitions do
    key = {__MODULE__, :dynamic_definitions}

    case :persistent_term.get(key, :missing) do
      :missing ->
        names =
          for version <- Version.supported(),
              document = Source.document(version, :common_types),
              document != nil,
              {name, schema} <- document["$defs"] || %{},
              dynamic_union?(schema),
              into: MapSet.new(["DataBinding"]),
              do: name

        :persistent_term.put(key, names)
        names

      names ->
        names
    end
  end

  defp dynamic_union?(%{} = schema) do
    case schema["oneOf"] || schema["anyOf"] do
      branches when is_list(branches) ->
        Enum.any?(branches, &match?(%{"$ref" => "#/$defs/DataBinding"}, &1)) and
          Enum.any?(branches, &function_call_branch?/1)

      _not_a_union ->
        false
    end
  end

  defp dynamic_union?(_schema), do: false

  defp function_call_branch?(%{"$ref" => "#/$defs/FunctionCall"}), do: true

  defp function_call_branch?(%{"allOf" => branches}) when is_list(branches),
    do: Enum.any?(branches, &match?(%{"$ref" => "#/$defs/FunctionCall"}, &1))

  defp function_call_branch?(_branch), do: false

  @doc """
  A catalog document that accepts whatever a catalog may define: any
  component object, any theme, and a well-formed function call of
  `version`. Message envelopes validate against it when the catalog a
  component belongs to is only known later.
  """
  @spec permissive_catalog(Version.protocol_version()) :: map()
  def permissive_catalog(version) do
    %{
      "$defs" => %{
        "anyComponent" => %{"type" => "object", "additionalProperties" => true},
        "theme" => true,
        "anyFunction" => function_stub(version)
      }
    }
  end

  defp common_types!(version) do
    case Source.document(version, :common_types) do
      nil -> raise ArgumentError, "no common types for protocol version #{inspect(version)}"
      document -> document
    end
  end

  @doc """
  The schema of a well-formed function call of `version`, standing in
  for a catalog's `anyFunction` union where only the shape of a call —
  not which functions exist — is to be checked.
  """
  @spec function_stub(Version.protocol_version()) :: map()
  def function_stub("v1.0"), do: @v1_0_function_stub
  def function_stub(_v0_9), do: @v0_9_function_stub
end

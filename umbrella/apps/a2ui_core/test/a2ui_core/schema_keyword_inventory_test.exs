defmodule A2UICore.SchemaKeywordInventoryTest do
  @moduledoc false
  # The engine silently ignores keywords it does not implement. This test
  # walks every vendored schema and catalog structurally and fails if any
  # schema position uses a keyword outside the engine's asserted or
  # annotation sets, so a spec bump cannot quietly weaken validation.

  use ExUnit.Case, async: true

  alias A2UICore.Schema.Engine
  alias A2UICore.Schema.Source

  # Keywords whose value is a map of name => subschema.
  @schema_maps ~w(properties patternProperties $defs components functions)
  # Keywords whose value is one subschema.
  @schema_values ~w(items not if then else contains additionalProperties
                    unevaluatedProperties propertyNames)
  # Keywords whose value is a list of subschemas.
  @schema_lists ~w(allOf anyOf oneOf prefixItems)

  test "every keyword in the vendored schemas and catalogs is known to the engine" do
    %{asserted: asserted, annotations: annotations} = Engine.keywords()
    known = MapSet.new(asserted ++ annotations)

    files = Path.wildcard(Path.join(Source.priv_dir(), "{schemas,catalogs}/**/*.json"))
    assert length(files) > 20

    unknown =
      for file <- files,
          keyword <- file |> File.read!() |> Jason.decode!() |> keywords_in(),
          not MapSet.member?(known, keyword),
          uniq: true,
          do: {Path.relative_to(file, Source.priv_dir()), keyword}

    assert unknown == []
  end

  test "the walker sees nested schema positions but skips data and names" do
    schema = %{
      "properties" => %{"Text" => %{"type" => "string", "dependentRequired" => %{}}},
      "const" => %{"notAKeyword" => 1},
      "enum" => [%{"alsoNot" => 1}],
      "default" => %{"nope" => 1},
      "examples" => [%{"nope" => 1}],
      "discriminator" => %{"propertyName" => "component"},
      "oneOf" => [%{"minContains" => 1}]
    }

    found = schema |> keywords_in() |> MapSet.new()

    assert MapSet.subset?(MapSet.new(~w(dependentRequired minContains type)), found)
    refute Enum.any?(~w(Text notAKeyword alsoNot nope propertyName), &(&1 in found))
  end

  defp keywords_in(schema) when is_map(schema) do
    Enum.flat_map(schema, fn {key, value} -> [key | nested(key, value)] end)
  end

  defp keywords_in(_boolean_or_other), do: []

  defp nested(key, value) when key in @schema_maps and is_map(value),
    do: Enum.flat_map(Map.values(value), &keywords_in/1)

  defp nested(key, value) when key in @schema_values, do: keywords_in(value)

  defp nested(key, value) when key in @schema_lists and is_list(value),
    do: Enum.flat_map(value, &keywords_in/1)

  defp nested(_key, _value), do: []
end

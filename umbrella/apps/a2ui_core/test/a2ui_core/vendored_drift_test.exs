defmodule A2UICore.VendoredDriftTest do
  @moduledoc false
  # The schemas and catalogs under `priv/` are vendored copies of the
  # pinned upstream checkout (SPEC_PIN). Every one must still equal its
  # reference counterpart exactly, so a SPEC_PIN bump that forgets to
  # re-vendor fails here rather than silently validating against stale
  # documents.

  use ExUnit.Case, async: true

  alias A2UICore.Schema.Source
  alias A2UICore.Test.Reference

  @schema_dirs %{
    "v0_9" => "specification/v0_9/json",
    "v0_9_1" => "specification/v0_9_1/json",
    "v1_0" => "specification/v1_0/json"
  }

  @catalogs %{
    "basic_v0_9_1.json" => "specification/v0_9_1/catalogs/basic/catalog.json",
    "basic_v1_0.json" => "catalogs/basic/v1/catalog.json",
    "testing_v1_0.json" => "specification/v1_0/test/testing_catalog.json",
    "mcp_v0_9.json" => "catalogs/mcp/catalog.json",
    "mcp_v1_0.json" => "catalogs/mcp/v1/catalog.json"
  }

  @priv Source.priv_dir()

  if Reference.root() do
    for {dir, reference_dir} <- @schema_dirs,
        file <- @priv |> Path.join("schemas/#{dir}") |> File.ls!() |> Enum.sort() do
      @tag :vendored_drift
      test "schemas/#{dir}/#{file} matches the reference" do
        assert_same(
          Path.join([@priv, "schemas", unquote(dir), unquote(file)]),
          Reference.path(Path.join(unquote(reference_dir), unquote(file)))
        )
      end
    end

    for {file, reference_rel} <- @catalogs do
      @tag :vendored_drift
      test "catalogs/#{file} matches the reference" do
        assert_same(
          Path.join([@priv, "catalogs", unquote(file)]),
          Reference.path(unquote(reference_rel))
        )
      end
    end

    @tag :vendored_drift
    test "every reference schema is vendored" do
      for {dir, reference_dir} <- @schema_dirs do
        assert @priv |> Path.join("schemas/#{dir}") |> File.ls!() |> Enum.sort() ==
                 reference_dir |> Reference.path() |> File.ls!() |> Enum.sort(),
               "schemas/#{dir} and #{reference_dir} list different files"
      end
    end

    @tag :vendored_drift
    test "every vendored schema directory has a reference mapping" do
      assert @priv |> Path.join("schemas") |> File.ls!() |> Enum.sort() ==
               @schema_dirs |> Map.keys() |> Enum.sort()

      assert @priv |> Path.join("catalogs") |> File.ls!() |> Enum.sort() ==
               @catalogs |> Map.keys() |> Enum.sort()
    end
  end

  defp assert_same(vendored, reference) do
    assert File.exists?(reference), "reference file missing: #{reference}"
    assert decode(vendored) === decode(reference), "#{vendored} drifted from #{reference}"
  end

  defp decode(path), do: path |> File.read!() |> Jason.decode!()
end

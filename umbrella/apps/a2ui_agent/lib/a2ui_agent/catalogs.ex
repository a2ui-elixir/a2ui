defmodule A2UIAgent.Catalogs do
  @moduledoc """
  Checks on the list of active catalogs that a format, parser or prompt
  works with.
  """

  alias A2UICore.{Catalog, Error, Version}

  @moduledoc since: "0.1.0"

  @doc """
  Returns `{:ok, catalogs}` when the list is non-empty, its catalog ids
  are distinct and every catalog targets the same protocol version.
  Otherwise a `:catalog` error.
  """
  @spec check(term()) :: {:ok, [Catalog.t()]} | {:error, Error.t()}
  def check([]), do: {:error, catalog_error("At least one catalog must be provided.")}

  def check([%Catalog{} | _] = catalogs) do
    duplicate =
      catalogs
      |> Enum.map(& &1.catalog_id)
      |> Enum.frequencies()
      |> Enum.find(fn {_id, count} -> count > 1 end)

    versions = catalogs |> Enum.map(&protocol_version/1) |> Enum.uniq() |> Enum.sort()

    cond do
      duplicate ->
        {:error, catalog_error("Duplicate catalog ID: '#{elem(duplicate, 0)}'.")}

      length(versions) > 1 ->
        {:error,
         catalog_error(
           "The catalogs target incompatible protocol versions: #{inspect(versions)}."
         )}

      true ->
        {:ok, catalogs}
    end
  end

  def check(_other), do: {:error, catalog_error("Expected a list of catalogs.")}

  @doc """
  The canonical protocol version (`"v1.0"`, `"v0.9.1"`, …) a catalog
  targets.
  """
  @spec protocol_version(Catalog.t()) :: String.t()
  def protocol_version(%Catalog{protocol_version: version}) do
    case Version.to_protocol_version(version) do
      {:ok, canonical} -> canonical
      :error -> version
    end
  end

  defp catalog_error(message), do: Error.new(:catalog, "CATALOG_ERROR", message)
end

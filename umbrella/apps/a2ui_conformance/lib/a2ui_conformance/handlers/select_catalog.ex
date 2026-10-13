defmodule A2UIConformance.Handlers.SelectCatalog do
  @moduledoc false

  # `select_catalog` (reference harness L1584-1699). The case is
  # self-contained: `args.surface` names the surface's default and
  # supported catalog ids, `args.catalogs` (optional) gives each a
  # protocol version (v1.0 by default), and `args.components` /
  # `args.functionCall` say what asks for a catalog.
  #
  # Without `expectError` the catalog selected for the last component (or
  # for the function call) must equal `expectSelected`. With it, mixing
  # protocol versions, a component naming a catalog the surface does not
  # support, or a component whose catalog's version differs from the
  # default's must raise a catalog error.

  @behaviour A2UIConformance.Handler

  import ExUnit.Assertions

  alias A2UIConformance.{Case, Matchers}
  alias A2UICore.Error

  @impl true
  def run(%Case{raw: raw}, _context) do
    args = if is_map(raw["args"]), do: raw["args"], else: %{}
    surface = if is_map(args["surface"]), do: args["surface"], else: %{}
    surface_id = surface["id"] || "main_surface"
    default_id = surface["defaultCatalogId"] || "basic"

    env = %{
      surface_id: surface_id,
      default_id: default_id,
      versions: versions(args, surface, default_id),
      args: args
    }

    case raw["expectError"] do
      nil -> select(env, raw)
      expected -> expect_error(env, expected)
    end

    :ok
  end

  defp versions(%{"catalogs" => %{} = catalogs}, _surface, _default_id),
    do: Map.new(catalogs, fn {id, definition} -> {id, version_of(definition)} end)

  defp versions(_args, surface, default_id) do
    ids =
      if is_list(surface["supportedCatalogIds"]),
        do: surface["supportedCatalogIds"],
        else: [default_id]

    Map.new(ids, &{&1, "v1.0"})
  end

  defp version_of(%{"protocolVersion" => version}) when is_binary(version), do: version
  defp version_of(_definition), do: "v1.0"

  defp default_version(env), do: Map.get(env.versions, env.default_id, "v1.0")

  # -- selection ----------------------------------------------------------------

  defp select(env, raw) do
    selected =
      cond do
        is_map(env.args["components"]) -> select_for_components(env)
        is_map(env.args["functionCall"]) -> select_for_function(env, env.args["functionCall"])
        true -> nil
      end

    if Map.has_key?(raw, "expectSelected"),
      do: assert(selected == raw["expectSelected"], "selected #{inspect(selected)}")
  end

  defp select_for_components(env) do
    Enum.reduce(env.args["components"], nil, fn {_id, data}, _last ->
      id = data["catalogId"]
      selected(env, id, unsupported(id, env))
    end)
  end

  defp select_for_function(env, call) do
    id = call["catalogId"]
    selected(env, id, "Catalog not found: #{id}")
  end

  # The catalog a component or function call asks for, or the default
  # when it names none.
  defp selected(env, id, _message) when id in [nil, ""], do: env.default_id

  defp selected(env, id, message) do
    unless Map.has_key?(env.versions, id), do: raise_catalog(message)
    id
  end

  # -- errors -------------------------------------------------------------------

  defp expect_error(env, expected) do
    error =
      try do
        check_versions(env)
        check_components(env)
        nil
      rescue
        error in Error -> error
      end

    if error == nil,
      do: flunk("expected an error matching #{inspect(expected)}, but the selection succeeded"),
      else: Matchers.assert_error(expected, error)
  end

  defp check_versions(env) do
    default = default_version(env)

    for {id, version} <- env.versions, version != default do
      raise_catalog(
        "Protocol version mismatch: cannot mix catalog '#{id}' (#{version}) with surface " <>
          "version #{default}."
      )
    end
  end

  defp check_components(%{args: %{"components" => %{} = components}} = env) do
    for {id, data} <- components, catalog = data["catalogId"], catalog not in [nil, ""] do
      unless Map.has_key?(env.versions, catalog), do: raise_catalog(unsupported(catalog, env))

      version = Map.fetch!(env.versions, catalog)
      default = default_version(env)

      if version != default do
        raise_catalog(
          "Component '#{id}' catalog protocol version #{version} mismatches default " <>
            "catalog protocol version #{default}."
        )
      end
    end
  end

  defp check_components(_env), do: :ok

  defp unsupported(catalog, env),
    do: "Catalog '#{catalog}' is not supported by surface '#{env.surface_id}'."

  @spec raise_catalog(String.t()) :: no_return()
  defp raise_catalog(message),
    do: Error.raise!(:catalog, "CATALOG_ERROR", message)
end

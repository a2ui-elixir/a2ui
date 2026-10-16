defmodule A2UIConformance.Handlers.EvaluateFunction do
  @moduledoc false

  # `evaluate_function` (reference harness `validate_evaluate_function_case`):
  # runs the named function of the case's first catalog with `args`
  # against a surface holding `dataModel` and compares the result with
  # `expect` (exact equality) or, with `expectError`, requires a matching
  # error.
  #
  # A function the catalog implements is executed directly, so its
  # errors surface; any other call goes through dynamic-value
  # resolution, where failures are reported as effects.
  #
  # With a `surface` block the call is evaluated on a surface built for
  # the case's protocol version instead (`_evaluate_function_on_surface`):
  # its catalogs are the `catalogPaths` built for that version, its
  # default the one `surface.catalogId` names, and the call goes through
  # catalog resolution, naming the case's `catalogId`. The first error
  # the evaluation reports is the outcome.

  @behaviour A2UIConformance.Handler

  import ExUnit.Assertions

  alias A2UIConformance.{Case, CaseCatalog, CatalogFixtures, Matchers}
  alias A2UICore.{Catalog, Error, SemVer}
  alias A2UICore.Catalog.Basic
  alias A2UICore.Resolution.DataContext
  alias A2UICore.State.DataModel

  @impl true
  def run(%Case{raw: raw} = test_case, _context) do
    name = raw["function"]
    expect_error = raw["expectError"] || raw["expect_error"]
    outcome = if raw["surface"], do: on_surface(raw), else: direct(test_case)

    case {outcome, expect_error} do
      {{:ok, value}, nil} ->
        Matchers.assert_json_equal(raw["expect"], value, "result of #{name}")
        :ok

      {{:error, error}, nil} ->
        flunk("#{name} failed: #{Exception.message(error)}")

      {{:error, error}, expected} ->
        Matchers.assert_error(expected, error)
        :ok

      {{:ok, value}, _expected} ->
        flunk("expected an error from #{name}, got #{inspect(value)}")
    end
  end

  defp direct(%Case{raw: raw} = test_case) do
    {:ok, [default | _] = catalogs} = CatalogFixtures.for_case(test_case)

    context =
      DataContext.new("/",
        data_model: DataModel.new(raw["dataModel"] || %{}),
        catalog: default,
        catalogs: Map.new(catalogs, &{&1.catalog_id, &1}),
        locale: raw["locale"] || "en-US"
      )

    invoke(default, raw["function"], raw["args"], context)
  end

  defp on_surface(raw) do
    version = raw["protocolVersion"]

    available =
      for path <- raw["catalogPaths"],
          catalog = load_catalog_path(path),
          SemVer.to_canonical(catalog.protocol_version) == SemVer.to_canonical(version),
          into: %{},
          do: {catalog.catalog_id, catalog}

    default_id = raw["surface"]["catalogId"]

    context =
      DataContext.new("/",
        data_model: DataModel.new(raw["dataModel"] || %{}),
        catalog: default_id && Map.fetch!(available, default_id),
        catalogs: available,
        protocol_version: version,
        surface_id: "main",
        locale: raw["locale"] || "en-US"
      )

    {value, effects} = DataContext.resolve_dynamic_value(context, surface_call(raw, context))

    case Enum.find(effects, &match?({:error, _}, &1)) do
      nil -> {:ok, value}
      {:error, payload} -> {:error, raised(payload)}
    end
  end

  defp surface_call(raw, context) do
    call_key = if DataContext.v1?(context), do: "@call", else: "call"
    call = %{call_key => raw["function"], "args" => raw["args"]}

    if Map.has_key?(raw, "catalogId"),
      do: Map.put(call, "catalogId", raw["catalogId"]),
      else: call
  end

  # The published basic catalogs are the library's own, which carry the
  # function implementations; any other file is built for the protocol
  # version it declares.
  defp load_catalog_path(path) do
    document = CaseCatalog.read(path)
    catalog_id = CaseCatalog.plain(document)["catalogId"]

    Enum.find_value(["v0.9", "v1.0"], fn version ->
      catalog = Basic.catalog(version)
      if catalog.catalog_id == catalog_id, do: catalog
    end) || Catalog.from_json!(document)
  end

  defp raised(%{code: "CATALOG_ERROR", message: message}),
    do: Error.new(:catalog, "CATALOG_ERROR", message)

  defp raised(%{code: code, message: message}), do: Error.new(:expression, code, message)

  defp invoke(catalog, name, args, context) do
    case Map.get(catalog.functions, name) do
      %{execute: execute} when is_function(execute, 2) ->
        case execute.(args, context) do
          {:ok, value} -> {:ok, value}
          {:ok, value, _effects} -> {:ok, value}
          {:error, error} -> {:error, error}
        end

      _not_executable ->
        {value, _effects} =
          DataContext.resolve_dynamic_value(context, %{"call" => name, "args" => args})

        {:ok, value}
    end
  end
end

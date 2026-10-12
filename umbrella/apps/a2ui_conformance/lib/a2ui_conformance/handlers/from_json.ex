defmodule A2UIConformance.Handlers.FromJson do
  @moduledoc false

  # `from_json` (reference harness `validate_from_json_case`, L972-1022):
  # builds a catalog from a catalog document (inline, or `catalogPath`
  # into the reference checkout) and checks what the case expects of it:
  # id and protocol version, that listed components and functions exist,
  # that its schema is self-contained, and that listed component payloads
  # validate (or fail). An unknown `expect` key fails the case.

  @behaviour A2UIConformance.Handler

  import ExUnit.Assertions

  alias A2UIConformance.{Case, CatalogFixtures, Matchers, Registry}
  alias A2UICore.Catalog
  alias A2UICore.Validation.Payload

  @expect_keys ~w(catalogId components functions invalidComponents protocolVersion
                  selfContained theme validComponents)

  @impl true
  def run(%Case{raw: raw, protocol_version: version}, _context) do
    schema = document(raw)

    catalog_id =
      CatalogFixtures.catalog_id(raw) ||
        if(raw["catalogPath"], do: schema["catalogId"])

    result = Catalog.from_json(schema, catalog_id: catalog_id, protocol_version: version)

    case {result, raw["expectError"]} do
      {{:error, error}, expected} when not is_nil(expected) ->
        Matchers.assert_error(expected, error)
        :ok

      {{:ok, _catalog}, expected} when not is_nil(expected) ->
        flunk("expected #{inspect(expected)}, but the catalog loaded")

      {{:error, error}, nil} ->
        flunk("catalog failed to load: #{Exception.message(error)}")

      {{:ok, catalog}, nil} ->
        check(catalog, raw["expect"] || %{})
        :ok
    end
  end

  @doc false
  @spec document(map()) :: map()
  def document(raw) do
    case raw["catalogPath"] do
      nil -> raw["catalogSchema"] || raw["catalog"] || raw["schema"] || raw
      path -> [Registry.reference_root(), path] |> Path.join() |> File.read!() |> Jason.decode!()
    end
  end

  defp check(catalog, expected) do
    unknown = Map.keys(expected) -- @expect_keys
    assert unknown == [], "Unknown from_json expect keys: #{inspect(Enum.sort(unknown))}"

    if id = expected["catalogId"], do: assert(catalog.catalog_id == id)
    if version = expected["protocolVersion"], do: assert(catalog.protocol_version == version)

    expected_names(expected["components"], &Catalog.get_component(catalog, &1), "component")

    expected_names(
      list_only(expected["functions"]),
      &Catalog.get_function(catalog, &1),
      "function"
    )

    if expected["selfContained"], do: assert_self_contained(Catalog.to_schema(catalog))
    check_payloads(catalog, expected)
  end

  defp list_only(names) when is_list(names), do: names
  defp list_only(_other), do: nil

  defp expected_names(nil, _lookup, _kind), do: :ok

  defp expected_names(names, lookup, kind) do
    for name <- if(is_map(names), do: Map.keys(names), else: names) do
      refute is_nil(lookup.(name)), "expected #{kind} #{inspect(name)} in the catalog"
    end

    :ok
  end

  defp check_payloads(catalog, expected) do
    for component <- expected["validComponents"] || [] do
      assert :ok == Payload.validate_component(catalog, component),
             "expected #{inspect(component)} to be valid"
    end

    for component <- expected["invalidComponents"] || [] do
      case Payload.validate_component(catalog, component) do
        {:error, %{category: :validation}} -> :ok
        other -> flunk("expected #{inspect(component)} to be invalid, got #{inspect(other)}")
      end
    end

    :ok
  end

  # Every `$ref` of the schema must be a `#` pointer that resolves inside
  # it, and there must be at least one.
  @doc false
  @spec assert_self_contained(map()) :: :ok
  def assert_self_contained(schema) do
    refs = collect_refs(schema)
    assert refs != [], "Catalog schema contains no references at all."

    for ref <- refs do
      assert String.starts_with?(ref, "#"), "Reference '#{ref}' leaves the catalog document."

      assert resolves?(schema, ref),
             "Reference '#{ref}' does not resolve within the catalog document."
    end

    :ok
  end

  defp collect_refs(%{} = node) do
    own = if is_binary(node["$ref"]), do: [node["$ref"]], else: []
    own ++ Enum.flat_map(node, fn {_key, value} -> collect_refs(value) end)
  end

  defp collect_refs(list) when is_list(list), do: Enum.flat_map(list, &collect_refs/1)
  defp collect_refs(_other), do: []

  defp resolves?(schema, "#" <> pointer) do
    tokens =
      pointer
      |> String.split("/")
      |> Enum.drop(1)
      |> Enum.map(&(&1 |> String.replace("~1", "/") |> String.replace("~0", "~")))

    walk(schema, tokens)
  end

  defp walk(_node, []), do: true

  defp walk(%{} = node, [token | rest]) do
    case node do
      %{^token => child} -> walk(child, rest)
      _missing -> false
    end
  end

  defp walk(_other, _tokens), do: false
end

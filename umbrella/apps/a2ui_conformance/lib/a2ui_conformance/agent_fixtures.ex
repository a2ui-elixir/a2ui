defmodule A2UIConformance.AgentFixtures do
  @moduledoc false

  # Shared pieces of the agent-SDK harness (reference
  # python/a2ui_agent/tests/conformance): conformance-relative paths,
  # catalog registrations built from case entries, and the catalog
  # expectations of the catalog suites.

  import ExUnit.Assertions

  alias A2UIAgent.{CatalogConfig, CatalogProvider, CatalogTransformer}
  alias A2UIConformance.Registry
  alias A2UICore.{Catalog, Error, Version}

  @doc "An absolute path for a conformance-relative one."
  @spec path(String.t()) :: Path.t()
  def path(relative), do: Path.join([Registry.reference_root(), "conformance", relative])

  @doc "Reads a conformance-relative JSON file."
  @spec load_json(String.t()) :: term()
  def load_json(relative), do: relative |> path() |> File.read!() |> Jason.decode!()

  @doc "A transformer for a case's `{\"component_pruning\": [...]}` entry."
  @spec transformer(map()) :: CatalogTransformer.t()
  def transformer(%{"component_pruning" => names}),
    do: CatalogTransformer.component_pruning(names)

  def transformer(%{"function_pruning" => names}), do: CatalogTransformer.function_pruning(names)

  @doc """
  The registration a catalog-suite entry describes (`_catalog_config`):
  a document without a `catalogId` takes its path as its id, and one
  without a `protocolVersion` runs under v1.0.
  """
  @spec catalog_config(String.t() | map()) :: CatalogConfig.t()
  def catalog_config(entry) when is_binary(entry), do: catalog_config(%{"catalog" => entry})

  def catalog_config(%{"catalog" => relative} = entry) do
    document = load_json(relative)

    catalog =
      CatalogProvider.load_document!(document,
        protocol_version: if(Map.has_key?(document, "protocolVersion"), do: nil, else: "v1.0"),
        catalog_id: if(Map.has_key?(document, "catalogId"), do: nil, else: relative)
      )

    CatalogConfig.new(catalog,
      transformers: Enum.map(entry["transformers"] || [], &transformer/1)
    )
  end

  @doc """
  Checks a catalog against a case's expectations (`_expect_catalog`).
  Name lists are exhaustive and compare as sets.
  """
  @spec expect_catalog(Catalog.t(), map()) :: :ok
  def expect_catalog(%Catalog{} = catalog, expected) do
    if Map.has_key?(expected, "catalog_id"),
      do: assert(catalog.catalog_id == expected["catalog_id"])

    if Map.has_key?(expected, "protocol_version"),
      do:
        assert(
          Version.to_protocol_version(catalog.protocol_version) ==
            Version.to_protocol_version(expected["protocol_version"])
        )

    for {key, field} <- [{"components", :components}, {"functions", :functions}],
        Map.has_key?(expected, key) do
      assert Enum.sort(Map.keys(Map.fetch!(catalog, field))) ==
               expected[key] |> Enum.uniq() |> Enum.sort(),
             "#{key} of #{catalog.catalog_id}"
    end

    :ok
  end

  @doc """
  Runs `fun`, which returns `{:ok, value}` or `{:error, error}` (or
  raises an `A2UICore.Error`), and asserts it failed as `expected`
  describes (`assert_error/2`).
  """
  @spec expect_error(map() | String.t(), (-> term())) :: :ok
  def expect_error(expected, fun) do
    result =
      try do
        fun.()
      rescue
        error in Error -> {:error, error}
      end

    case result do
      {:error, %Error{} = error} -> assert_error(expected, error)
      other -> flunk("expected an error #{inspect(expected)}, got #{inspect(other)}")
    end

    :ok
  end

  # The agent harness's error classes (`CATEGORY_TO_EXCEPTION`) with
  # their subclasses: integrity and recursion errors are validation
  # errors.
  @categories %{
    "ParseError" => [:parse],
    "ValidationError" => [:validation, :integrity, :recursion],
    "CatalogError" => [:catalog],
    "IntegrityError" => [:integrity],
    "RecursionError" => [:recursion],
    "CompilationError" => [:compilation]
  }

  @doc """
  The agent harness's `assert_raises`: the error's category must be the
  expected class or a subclass (an unknown category accepts any error), a
  `message` is a regular expression searched for in the error message
  (with the harness's alternates for pydantic phrasings), and each
  expected detail must match a detail's path and code exactly. A bare
  string expectation is a message.
  """
  @spec assert_error(map() | String.t(), Error.t()) :: :ok
  def assert_error(expected, %Error{} = error) when is_binary(expected),
    do: assert_error(%{"message" => expected}, error)

  def assert_error(expected, %Error{} = error) when is_map(expected) do
    case Map.fetch(@categories, expected["category"]) do
      {:ok, allowed} ->
        assert error.category in allowed,
               "expected #{expected["category"]}, got #{inspect(error.category)}: #{error.message}"

      :error ->
        :ok
    end

    case expected["message"] do
      message when message in [nil, ""] ->
        :ok

      message ->
        assert Regex.match?(Regex.compile!(align(message)), error.message),
               "#{inspect(message)} not found in #{inspect(error.message)}"
    end

    for %{"path" => path, "code" => code} <- expected["details"] || [] do
      assert Enum.any?(error.details, &(&1.path == path and to_string(&1.code) == code)),
             "detail #{path} #{code} not found in #{inspect(error.details)}"
    end

    :ok
  end

  defp align(message) do
    cond do
      message =~ "required property" ->
        "(#{message}|Field required)"

      message =~ "'v0.9' was expected" ->
        "(#{message}|Input should be 'v0.9')"

      message =~ "is not of type" ->
        "(#{message}|Input should be a valid)"

      message =~ "Validation failed" ->
        "(#{message}|Field required|Extra inputs are not permitted)"

      true ->
        message
    end
  end

  # -- formats -----------------------------------------------------------------------

  @default_catalog "test_data/catalogs/simplified_catalog_v1_0.json"

  @doc """
  The registration a format-suite catalog entry describes
  (`catalog_config_from_document`): `{"catalog": ..., "transformers":
  [...]}`, an inline document (id `"inline"` and v1.0 unless it says
  otherwise) or a path (id from the file name and v1.0 unless the file
  says otherwise).
  """
  @spec format_catalog_config(String.t() | map()) :: CatalogConfig.t()
  def format_catalog_config(%{"catalog" => ref} = entry) do
    config = format_catalog_config(ref)

    CatalogConfig.new(config.catalog,
      transformers: Enum.map(entry["transformers"] || [], &transformer/1)
    )
  end

  def format_catalog_config(%{} = document) do
    document
    |> CatalogProvider.load_document!(
      protocol_version: if(Map.has_key?(document, "protocolVersion"), do: nil, else: "v1.0"),
      catalog_id: if(Map.has_key?(document, "catalogId"), do: nil, else: "inline")
    )
    |> CatalogConfig.new()
  end

  def format_catalog_config(relative) when is_binary(relative) do
    document = load_json(relative)

    {:ok, config} =
      CatalogConfig.from_path(path(relative),
        protocol_version: if(Map.has_key?(document, "protocolVersion"), do: nil, else: "v1.0"),
        catalog_id:
          if(Map.has_key?(document, "catalogId"), do: nil, else: Path.basename(relative, ".json"))
      )

    config
  end

  @doc "The transformed catalogs a format case names (`_catalogs_for`)."
  @spec catalogs_for(map()) :: [Catalog.t()]
  def catalogs_for(%{"catalogs" => entries}),
    do: Enum.map(entries, &format_catalog_config(&1).transformed)

  def catalogs_for(args),
    do: [format_catalog_config(args["catalog"] || @default_catalog).transformed]

  @doc "The example turns a case names, loaded from their files."
  @spec examples(map()) :: [[map()]] | nil
  def examples(args) do
    case args["examples"] do
      files when is_list(files) and files != [] -> Enum.map(files, &load_json/1)
      _none -> nil
    end
  end

  @doc "A response part as the harness writes it (`part_to_dict`)."
  @spec part_to_map(A2UIAgent.DirectJson.Parser.part()) :: map()
  def part_to_map({:text, text}), do: %{"text" => text}
  def part_to_map({:a2ui, messages}), do: %{"a2ui" => messages}
end

defmodule A2UIConformance.Registry do
  @moduledoc false

  # Discovers conformance suites in the upstream checkout and parses
  # them into `A2UIConformance.Case` structs.
  #
  # The reference root is resolved, in order, from:
  #
  #   1. the `A2UI_REFERENCE_ROOT` environment variable,
  #   2. `Application.get_env(:a2ui_conformance, :reference_root)`,
  #   3. an upward directory walk looking for `reference/a2ui/conformance`.
  #
  # Per the upstream README, `agent/builder/` and `agent/macros/` use a
  # different case vocabulary (golden AST suites) and are excluded from
  # the schema-validated corpus.

  alias A2UIConformance.{Case, Yaml}

  @default_root_walk_depth 8
  @excluded_suites ~r{\Aagent/(builder|macros)/}
  @case_roots ["core", "agent", "extensions"]

  @doc """
  Resolves the path of the upstream `reference/a2ui` checkout.
  """
  @spec reference_root() :: Path.t() | nil
  def reference_root do
    System.get_env("A2UI_REFERENCE_ROOT") ||
      Application.get_env(:a2ui_conformance, :reference_root) ||
      walk_up(File.cwd!(), @default_root_walk_depth)
  end

  defp walk_up(_dir, 0), do: nil
  defp walk_up("/", _depth), do: nil

  defp walk_up(dir, depth) do
    candidate = Path.join(dir, "reference/a2ui")

    if File.dir?(Path.join(candidate, "conformance")) do
      candidate
    else
      walk_up(Path.dirname(dir), depth - 1)
    end
  end

  @doc """
  Returns all discoverable case-suite files (relative paths under
  `conformance/`), in deterministic order.

  Only the case roots (`core/`, `agent/`, `extensions/`) are walked —
  `test_data/` holds fixture documents (node-resolution data, catalogs,
  goldens), not case suites, matching the reference harness's discovery.
  """
  @spec suite_files() :: [String.t()] | {:error, term()}
  def suite_files do
    case reference_root() do
      nil ->
        {:error, :reference_checkout_not_found}

      root ->
        conformance_dir = Path.join(root, "conformance")

        @case_roots
        |> Enum.flat_map(fn rel_root ->
          Path.wildcard(Path.join([conformance_dir, rel_root, "**/*.yaml"]))
        end)
        |> Enum.map(&Path.relative_to(&1, conformance_dir))
        |> Enum.sort()
    end
  end

  @doc """
  Loads every suite file and returns its cases.

  Returns `{:ok, cases}` or `{:error, reason}` when the checkout is
  missing or a suite fails to parse. Suite-level parse failures are
  collected per-file and reported — the harness must never silently
  drop a suite (mirrors the reference's `SUITE_LOAD_ERRORS` check).
  """
  @spec load_all() :: {:ok, [Case.t()]} | {:error, term()}
  def load_all do
    case reference_root() do
      nil ->
        {:error, :reference_checkout_not_found}

      root ->
        files = suite_files()

        {cases, errors} = load_all_files(root, files)

        if errors == [] do
          {:ok, cases}
        else
          {:error, {:suite_load_errors, Enum.reverse(errors)}}
        end
    end
  end

  @spec load_all_files(Path.t(), [String.t()]) :: {[Case.t()], [{String.t(), term()}]}
  defp load_all_files(root, files) do
    Enum.flat_map_reduce(files, [], fn rel, errs ->
      case load_suite(root, rel) do
        {:ok, cases} -> {cases, errs}
        {:error, reason} -> {[], [{rel, reason} | errs]}
      end
    end)
  end

  @doc """
  Loads one suite file into cases. The file must contain one YAML list
  of case mappings at the top level.
  """
  @spec load_suite(Path.t(), String.t()) :: {:ok, [Case.t()]} | {:error, term()}
  def load_suite(root, rel) do
    if Regex.match?(@excluded_suites, rel) do
      {:ok, []}
    else
      path = Path.join([root, "conformance", rel])

      case Yaml.load_file(path) do
        {:ok, [cases]} when is_list(cases) ->
          {:ok, Enum.map(cases, &build_case(rel, &1))}

        {:ok, _multi_doc} ->
          {:error, {:expected_single_document, rel}}

        {:error, reason} ->
          {:error, {rel, reason}}
      end
    end
  end

  defp build_case(rel, raw) when is_map(raw) do
    name = raw["name"] || raise ArgumentError, "case in #{rel} is missing 'name'"
    Case.new(rel, name, raw)
  end

  defp build_case(rel, other) do
    raise ArgumentError, "entry in #{rel} is not a mapping: #{inspect(other)}"
  end
end

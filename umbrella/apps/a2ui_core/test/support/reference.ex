defmodule A2UICore.Test.Reference do
  @moduledoc false
  # Locates the pinned upstream checkout (`reference/a2ui`, see SPEC_PIN)
  # for the fidelity tests, and owns the file discovery those tests use
  # to generate cases — so the guard test can prove that discovery found
  # something instead of silently generating zero tests.
  #
  # Resolution order:
  #
  #   1. `A2UI_REFERENCE_ROOT` (expanded against the current directory),
  #   2. an upward walk from this file looking for `reference/a2ui`.

  @walk_depth 8

  @bundle_globs [
    {"v1.0", "catalogs/basic/v1/examples/*.json"},
    {"v0.9.1", "specification/v0_9_1/catalogs/basic/examples/*.json"}
  ]

  @jsonl_files [
    {"v1.0", "specification/v1_0/test/cases/contact_form_example.jsonl"},
    {"v0.9.1", "specification/v0_9_1/test/cases/contact_form_example.jsonl"}
  ]

  @spec_case_dirs ["v1_0", "v0_9_1"]

  @doc "The upstream checkout root, or nil when absent."
  @spec root() :: Path.t() | nil
  def root do
    case System.get_env("A2UI_REFERENCE_ROOT") do
      nil -> walk_up(__DIR__, @walk_depth)
      "" -> walk_up(__DIR__, @walk_depth)
      env -> if File.dir?(Path.expand(env)), do: Path.expand(env), else: nil
    end
  end

  @doc "True when CI demands the corpus (`A2UI_REQUIRE_REFERENCE=1`)."
  @spec required?() :: boolean()
  def required?, do: System.get_env("A2UI_REQUIRE_REFERENCE") in ["1", "true"]

  @doc "Absolute path of a file inside the checkout (nil when absent)."
  @spec path(String.t()) :: Path.t() | nil
  def path(rel) do
    case root() do
      nil -> nil
      root -> Path.join(root, rel)
    end
  end

  @doc "`[{version, file}]` for every basic-catalog example bundle."
  @spec bundle_files() :: [{String.t(), Path.t()}]
  def bundle_files do
    for {version, glob} <- @bundle_globs,
        root = root(),
        root != nil,
        file <- Path.wildcard(Path.join(root, glob)),
        do: {version, file}
  end

  @doc "`[{version, file}]` for the JSONL contact-form samples."
  @spec jsonl_files() :: [{String.t(), Path.t()}]
  def jsonl_files do
    for {version, rel} <- @jsonl_files,
        file = path(rel),
        file != nil and File.exists?(file),
        do: {version, file}
  end

  @doc "`[{dir, version, file}]` for every ajv-calibrated spec case suite."
  @spec spec_case_files() :: [{String.t(), String.t(), Path.t()}]
  def spec_case_files do
    for dir <- @spec_case_dirs,
        root = root(),
        root != nil,
        file <- Path.wildcard(Path.join([root, "specification", dir, "test/cases/*.json"])),
        do: {dir, String.replace(dir, "_", "."), file}
  end

  defp walk_up(_dir, 0), do: nil

  defp walk_up(dir, depth) do
    candidate = Path.join(dir, "reference/a2ui")

    cond do
      File.dir?(Path.join(candidate, "specification")) -> candidate
      Path.dirname(dir) == dir -> nil
      true -> walk_up(Path.dirname(dir), depth - 1)
    end
  end
end

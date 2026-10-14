defmodule A2UIPhoenix.Test.Reference do
  @moduledoc false
  # Locates the pinned upstream checkout (`reference/a2ui`, see SPEC_PIN):
  # `A2UI_REFERENCE_ROOT`, else an upward walk from this file.

  @walk_depth 8

  @bundle_globs [
    {"v1.0", "catalogs/basic/v1/examples/*.json"},
    {"v0.9.1", "specification/v0_9_1/catalogs/basic/examples/*.json"}
  ]

  def root do
    case System.get_env("A2UI_REFERENCE_ROOT") do
      env when env in [nil, ""] -> walk_up(__DIR__, @walk_depth)
      env -> if File.dir?(Path.expand(env)), do: Path.expand(env)
    end
  end

  def required?, do: System.get_env("A2UI_REQUIRE_REFERENCE") in ["1", "true"]

  def path(rel), do: root() && Path.join(root(), rel)

  def bundle_files do
    for {version, glob} <- @bundle_globs,
        root = root(),
        root != nil,
        file <- Path.wildcard(Path.join(root, glob)),
        do: {version, file}
  end

  def jsonl(rel) do
    rel
    |> path()
    |> File.read!()
    |> String.split("\n", trim: true)
    |> Enum.map(&Jason.decode!/1)
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

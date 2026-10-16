defmodule A2UIConformance.Handlers.Skills do
  @moduledoc false

  # The skill cases of conformance/agent/skill.yaml
  # (python/a2ui_agent/tests/conformance/test_skill_conformance.py): a
  # skill generated from an Express format over the case's catalog must
  # equal its golden file byte for byte, and a skill set must hold the
  # listed skills. Paths in these cases are relative to the repository
  # root, not to `conformance/`.

  @behaviour A2UIConformance.Handler

  import ExUnit.Assertions

  alias A2UIAgent.{CatalogConfig, Express, Skill, SkillGenerator}
  alias A2UIConformance.{Case, Registry}

  @impl true
  def run(%Case{action: action, raw: raw}, _context) do
    args = raw["args"] || %{}
    {:ok, format} = Express.new(catalogs(args))
    run_action(action, format, args, raw)
    :ok
  end

  defp catalogs(%{"catalog" => relative}) do
    {:ok, config} = CatalogConfig.from_path(Path.join(Registry.reference_root(), relative))
    [config.transformed]
  end

  defp catalogs(_args), do: []

  defp run_action("from_format", format, args, raw) do
    assert {:ok, skill} = SkillGenerator.skill(format, name: Map.get(args, "name", "a2ui"))
    assert_golden(skill, raw["expected_file"])
  end

  defp run_action("core_syntax", format, args, raw) do
    skill = SkillGenerator.core_skill(format, name: Map.get(args, "name", "a2ui-core"))
    assert_golden(skill, raw["expected_file"])
  end

  defp run_action("from_catalog", format, _args, raw) do
    assert {:ok, skill} = SkillGenerator.catalog_skill(format)
    assert_golden(skill, raw["expected_file"])
  end

  defp run_action("skill_set", format, _args, raw) do
    assert {:ok, skills} = SkillGenerator.skill_set(format)
    filenames = Enum.map(skills, & &1.filename)

    for expected <- raw["expected_skills"] || [],
        do: assert(expected in filenames, "#{expected} not in #{inspect(filenames)}")
  end

  defp assert_golden(skill, relative) do
    expected = File.read!(Path.join(Registry.reference_root(), relative))
    assert Skill.to_markdown(skill) == expected, "skill differs from #{relative}"
  end
end

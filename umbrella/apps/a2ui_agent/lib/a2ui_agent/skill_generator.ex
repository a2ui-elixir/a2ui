defmodule A2UIAgent.SkillGenerator do
  @moduledoc """
  Packages an inference format's prompt as skills
  (`A2UIAgent.Skill`).

      {:ok, format} = A2UIAgent.Express.new([catalog])

      {:ok, skill} = A2UIAgent.SkillGenerator.skill(format, name: "a2ui")
      {:ok, skills} = A2UIAgent.SkillGenerator.skill_set(format)
      Enum.map(skills, & &1.filename)
      #=> ["a2ui-core/SKILL.md", "a2ui-basic/SKILL.md"]

  A monolithic skill (`skill/2`) holds the whole prompt: the format's
  rules, each catalog's instructions and the examples. A skill set
  (`skill_set/2`) splits it into a core skill with the rules
  (`core_skill/2`) and one skill per catalog (`catalog_skill/3`), named
  after the catalog: `a2ui-<name>`, where the name is the last part of
  the catalog id that is not a file or a version.

  The format must implement the optional `A2UIAgent.Format` callbacks
  that give its prompt's pieces, as `A2UIAgent.Express` does.
  """

  alias A2UIAgent.Skill
  alias A2UICore.{Catalog, Error}

  @moduledoc since: "0.1.0"

  @doc """
  One skill with the whole prompt. Options: `:name` (default `"a2ui"`),
  `:description` and `:catalogs` (default: the format's).
  """
  @spec skill(struct(), keyword()) :: {:ok, Skill.t()} | {:error, Error.t()}
  def skill(%module{} = format, options \\ []) do
    name = Keyword.get(options, :name, "a2ui")
    catalogs = Keyword.get(options, :catalogs) || module.catalogs(format)

    with {:ok, examples} <- unique_examples(format, catalogs) do
      instructions =
        catalogs
        |> Enum.map(&module.catalog_instructions(format, &1.catalog_id))
        |> Enum.reject(&(&1 == ""))

      parts = Enum.reject([module.base_rules(format)], &(&1 == "")) ++ instructions

      parts =
        if examples == [],
          do: parts,
          else: parts ++ ["### Examples:\n\n" <> Enum.join(examples, "\n\n")]

      description =
        options[:description] ||
          "Generates interactive user interface components for user requests."

      {:ok, Skill.new(name, description, Enum.join(parts, "\n\n") <> "\n")}
    end
  end

  # Each catalog's examples, without repeats: a format whose examples
  # are not kept per catalog gives the same ones for every catalog.
  defp unique_examples(%module{} = format, catalogs) do
    Enum.reduce_while(catalogs, {:ok, []}, fn catalog, {:ok, acc} ->
      case module.examples(format, catalog.catalog_id) do
        {:ok, ""} -> {:cont, {:ok, acc}}
        {:ok, examples} -> {:cont, {:ok, if(examples in acc, do: acc, else: acc ++ [examples])}}
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  @doc """
  The skill with the format's rules. Options: `:name` (default
  `"a2ui-core"`) and `:description`.
  """
  @spec core_skill(struct(), keyword()) :: Skill.t()
  def core_skill(%module{} = format, options \\ []) do
    name = Keyword.get(options, :name, "a2ui-core")

    description =
      options[:description] ||
        "Core A2UI protocol instructions and syntax rules for UI generation."

    Skill.new(name, description, String.trim(module.base_rules(format)) <> "\n")
  end

  @doc """
  The skill of one catalog (default: the format's first): its
  instructions and, unless `include_examples: false`, the examples.
  Options: `:name` (default `"a2ui-<name>"`), `:description` and
  `:include_examples`.
  """
  @spec catalog_skill(struct(), Catalog.t() | nil, keyword()) ::
          {:ok, Skill.t()} | {:error, Error.t()}
  def catalog_skill(%module{} = format, catalog \\ nil, options \\ []) do
    catalog = catalog || hd(module.catalogs(format))

    examples =
      if Keyword.get(options, :include_examples, true),
        do: module.examples(format, catalog.catalog_id),
        else: {:ok, ""}

    with {:ok, examples} <- examples,
         do: {:ok, build_catalog_skill(format, catalog, examples, options)}
  end

  defp build_catalog_skill(%module{} = format, catalog, examples, options) do
    clean = clean_name(catalog.catalog_id)
    name = options[:name] || "a2ui-#{clean}"
    body = module.catalog_instructions(format, catalog.catalog_id)
    body = if examples == "", do: body, else: body <> "\n\n### Examples:\n\n" <> examples

    description =
      options[:description] ||
        "UI component catalog signatures for #{clean}. Use when building #{clean} user " <>
          "interface components."

    Skill.new(name, description, String.trim(body) <> "\n")
  end

  @doc """
  The core skill and one skill per catalog (default: the format's
  catalogs). Examples a format gives every catalog go only into the
  first catalog's skill. Options: `:catalogs` and `:core_name`.
  """
  @spec skill_set(struct(), keyword()) :: {:ok, [Skill.t()]} | {:error, Error.t()}
  def skill_set(%module{} = format, options \\ []) do
    core = core_skill(format, name: Keyword.get(options, :core_name, "a2ui-core"))
    catalogs = Keyword.get(options, :catalogs) || module.catalogs(format)

    catalogs
    |> Enum.reduce_while({:ok, [core], []}, &add_catalog_skill(format, &1, &2))
    |> case do
      {:ok, skills, _seen} -> {:ok, skills}
      error -> error
    end
  end

  defp add_catalog_skill(%module{} = format, catalog, {:ok, skills, seen}) do
    case module.examples(format, catalog.catalog_id) do
      {:ok, examples} ->
        shown = if examples in seen, do: "", else: examples
        skill = build_catalog_skill(format, catalog, shown, [])
        {:cont, {:ok, skills ++ [skill], [examples | seen]}}

      {:error, _} = error ->
        {:halt, error}
    end
  end

  @doc """
  The name a catalog's skill takes after: the last part of its id that
  is not a file name or a version, in lower case.

      iex> A2UIAgent.SkillGenerator.clean_name("https://a2ui.org/specification/v1_0/catalogs/basic/catalog.json")
      "basic"
      iex> A2UIAgent.SkillGenerator.clean_name("acme/widgets/v2")
      "widgets"
  """
  @spec clean_name(String.t() | nil) :: String.t()
  def clean_name(catalog_id) when catalog_id in [nil, ""], do: "basic"

  def clean_name(catalog_id) do
    parts =
      catalog_id
      |> String.replace("\\", "/")
      |> String.split("/")
      |> Enum.reject(&(&1 == "" or String.ends_with?(&1, ".json")))

    name =
      cond do
        not String.contains?(catalog_id, ["/", "\\"]) -> catalog_id
        parts == [] -> catalog_id
        true -> last_name(Enum.reverse(parts))
      end

    String.downcase(name)
  end

  # The last part, or the one before it when the last is a version.
  defp last_name(["v" <> _, previous | _]), do: previous
  defp last_name([last | _]), do: last
end

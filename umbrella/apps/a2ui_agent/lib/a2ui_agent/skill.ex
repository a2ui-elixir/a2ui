defmodule A2UIAgent.Skill do
  @moduledoc """
  A skill package: a markdown document with YAML frontmatter (`name`,
  `description` and optional `metadata`) that teaches an agent to write
  A2UI, stored as `<name>/SKILL.md`.

      iex> skill = A2UIAgent.Skill.new("a2ui-core", "Core rules.", "# Rules\\n")
      iex> skill.filename
      "a2ui-core/SKILL.md"
      iex> A2UIAgent.Skill.to_markdown(skill)
      "---\\nname: a2ui-core\\ndescription: Core rules.\\n---\\n\\n# Rules\\n"

  The frontmatter is written as PyYAML's `yaml.dump` writes it, so that
  skills match the reference's byte for byte: plain scalars where YAML
  allows them, folded at 80 columns, and quoted scalars otherwise.
  `A2UIAgent.SkillGenerator` builds skills from an inference format.
  """

  @moduledoc since: "0.1.0"

  @enforce_keys [:name, :description, :content, :filename]
  defstruct [:name, :description, :content, :filename, metadata: []]

  @type t :: %__MODULE__{
          name: String.t(),
          description: String.t(),
          content: String.t(),
          filename: String.t(),
          metadata: [{String.t(), term()}] | map()
        }

  @width 80

  @doc """
  A skill. Options: `:metadata` (pairs or a map, written in order or by
  sorted key) and `:filename` (default `"<name>/SKILL.md"`).
  """
  @spec new(String.t(), String.t(), String.t(), keyword()) :: t()
  def new(name, description, content, options \\ []) do
    %__MODULE__{
      name: name,
      description: description,
      content: content,
      metadata: Keyword.get(options, :metadata, []),
      filename: Keyword.get(options, :filename) || "#{name}/SKILL.md"
    }
  end

  @doc "The skill as markdown: the frontmatter, a blank line, then the content."
  @spec to_markdown(t()) :: String.t()
  def to_markdown(%__MODULE__{} = skill) do
    pairs = [{"name", skill.name}, {"description", skill.description}]
    metadata = metadata_pairs(skill.metadata)
    pairs = if metadata == [], do: pairs, else: pairs ++ [{"metadata", metadata}]
    "---\n#{frontmatter(pairs, 0)}\n---\n\n#{String.trim(skill.content)}\n"
  end

  defp metadata_pairs(%{} = map), do: map |> Map.to_list() |> Enum.sort()

  defp metadata_pairs(pairs) when is_list(pairs),
    do: Enum.map(pairs, fn {k, v} -> {to_string(k), v} end)

  defp frontmatter(pairs, indent) do
    Enum.map_join(pairs, "\n", fn
      {key, nested} when is_list(nested) and nested != [] and is_tuple(hd(nested)) ->
        pad(indent) <> scalar_key(key) <> ":\n" <> frontmatter(nested, indent + 2)

      {key, %{} = nested} ->
        pad(indent) <> scalar_key(key) <> ":\n" <> frontmatter(metadata_pairs(nested), indent + 2)

      {key, value} ->
        prefix = pad(indent) <> scalar_key(key) <> ":"
        prefix <> scalar(value, String.length(prefix), indent + 2)
    end)
  end

  defp pad(indent), do: String.duplicate(" ", indent)

  defp scalar_key(key), do: key |> scalar(0, 0) |> String.trim_leading()

  # A scalar after `key:`, starting at `column`; folded lines start at
  # `indent`.
  defp scalar(value, column, indent) when is_binary(value) do
    cond do
      plain?(value) ->
        " " <> fold(value, column + 1, indent, "")

      printable_ascii?(value) ->
        " '" <> fold(String.replace(value, "'", "''"), column + 2, indent, "'")

      true ->
        " " <> double_quoted(value)
    end
  end

  defp scalar(true, _column, _indent), do: " true"
  defp scalar(false, _column, _indent), do: " false"
  defp scalar(nil, _column, _indent), do: " null"
  defp scalar(value, _column, _indent) when is_integer(value), do: " #{value}"
  defp scalar(value, _column, _indent) when is_float(value), do: " #{Float.to_string(value)}"
  defp scalar(value, column, indent), do: scalar(inspect(value), column, indent)

  # PyYAML breaks a line at a single space once the line is past the
  # width.
  defp fold(text, column, indent, closing) do
    {lines, _column} =
      ~r/ +|[^ ]+/
      |> Regex.scan(text)
      |> List.flatten()
      |> Enum.reduce({[], column}, fn run, {acc, column} ->
        if run == " " and column > @width,
          do: {["\n" <> pad(indent) | acc], indent},
          else: {[run | acc], column + String.length(run)}
      end)

    (lines |> Enum.reverse() |> Enum.join()) <> closing
  end

  @bool_or_null ~w(yes Yes YES no No NO true True TRUE false False FALSE on On ON off Off OFF ~ null Null NULL)

  defp plain?(text) do
    printable_ascii?(text) and text != "" and String.trim(text) == text and
      not String.starts_with?(text, ~w(# , [ ] { } & * ! | > ' " % @ `)) and
      not Regex.match?(~r/\A[-?:]( |\z)/, text) and not String.contains?(text, [": ", " #"]) and
      not String.ends_with?(text, ":") and text not in @bool_or_null and not number?(text)
  end

  defp number?(text),
    do:
      Regex.match?(
        ~r/\A[-+]?(\d[\d_]*(\.\d*)?|\.\d+)([eE][-+]?\d+)?\z|\A0[xob][0-9a-fA-F_]+\z|\A[-+]?\.(inf|Inf|INF|nan|NaN|NAN)\z/,
        text
      )

  defp printable_ascii?(text), do: Regex.match?(~r/\A[\x20-\x7E]*\z/, text)

  defp double_quoted(text) do
    escaped =
      text
      |> String.to_charlist()
      |> Enum.map_join(fn
        ?" -> "\\\""
        ?\\ -> "\\\\"
        ?\n -> "\\n"
        ?\t -> "\\t"
        ?\r -> "\\r"
        char when char in 0x20..0x7E -> <<char>>
        char when char <= 0xFF -> "\\x" <> hex(char, 2)
        char when char <= 0xFFFF -> "\\u" <> hex(char, 4)
        char -> "\\U" <> hex(char, 8)
      end)

    ~s("#{escaped}")
  end

  defp hex(char, digits), do: char |> Integer.to_string(16) |> String.pad_leading(digits, "0")

  @doc """
  Writes skills into `directory`, each at its filename, and returns the
  markdown written by filename.

  Each skill's own top-level directory (such as `a2ui-core/`) is removed
  first, so that nothing from an earlier export stays behind; other
  entries of `directory` are left alone.
  """
  @spec export([t()], Path.t()) :: {:ok, %{optional(String.t()) => String.t()}} | {:error, term()}
  def export(skills, directory) do
    File.mkdir_p!(directory)

    skills
    |> Enum.flat_map(fn skill ->
      case Path.split(skill.filename) do
        [top, _ | _] when top not in [".", "..", "/"] -> [top]
        _single -> []
      end
    end)
    |> Enum.uniq()
    |> Enum.each(&File.rm_rf!(Path.join(directory, &1)))

    written =
      Map.new(skills, fn skill ->
        path = Path.join(directory, skill.filename)
        File.mkdir_p!(Path.dirname(path))
        markdown = to_markdown(skill)
        File.write!(path, markdown)
        {skill.filename, markdown}
      end)

    {:ok, written}
  rescue
    error in File.Error -> {:error, error}
  end
end

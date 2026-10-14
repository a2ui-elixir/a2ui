defmodule A2UIAgent.DirectJson.Prompt do
  @moduledoc """
  The system prompt snippet of the direct JSON format.

  The snippet has three parts, separated by blank lines:

    1. `## Workflow Description:` and `workflow_rules/0`;
    2. the schemas, between `---BEGIN A2UI JSON SCHEMA---` and
       `---END A2UI JSON SCHEMA---` lines (`schema_prompt/2`);
    3. `### Examples:` and each example turn as an `<a2ui-json>` block,
       when there are examples.
  """

  alias A2UIAgent.{Catalogs, SchemaPruning}
  alias A2UIAgent.DirectJson.Parser
  alias A2UICore.{Catalog, Error}
  alias A2UICore.Schema.Source

  @moduledoc since: "0.1.0"

  @schema_start "---BEGIN A2UI JSON SCHEMA---"
  @schema_end "---END A2UI JSON SCHEMA---"

  @workflow_rules """

  The generated response MUST follow these rules:
  - The response can contain one or more A2UI JSON blocks.
  - Each A2UI JSON block MUST be wrapped in `<a2ui-json>` and `</a2ui-json>` tags.
  - Between or around these blocks, you can provide conversational text.
  - The JSON part MUST be a single, raw JSON object (usually a list of A2UI messages) and MUST validate against the provided A2UI JSON SCHEMA.
  - Top-Down Component Ordering: Within the `components` list of a message:
      - The 'root' component MUST be the FIRST element.
      - Parent components MUST appear before their child components.
      This specific ordering allows the streaming parser to yield and render the UI incrementally as it arrives.
  """

  @doc """
  The workflow rules every direct JSON prompt starts with.
  """
  @spec workflow_rules() :: String.t()
  def workflow_rules, do: @workflow_rules

  @doc """
  Assembles the prompt snippet. Options: `:examples` (a list of turns,
  each a list of messages) and `:allowed_messages` (see
  `schema_prompt/2`).
  """
  @spec generate([Catalog.t()], keyword()) :: {:ok, String.t()} | {:error, Error.t()}
  def generate(catalogs, options \\ []) do
    with {:ok, schemas} <- schema_prompt(catalogs, options[:allowed_messages]) do
      parts = ["## Workflow Description:\n#{@workflow_rules}", schemas]

      parts =
        case examples(options[:examples]) do
          "" -> parts
          examples -> parts ++ ["### Examples:\n#{examples}"]
        end

      {:ok, Enum.join(parts, "\n\n")}
    end
  end

  @doc """
  The schemas that describe the catalogs to the model: the
  agent-to-renderer schema of the catalogs' protocol version (pruned to
  `allowed_messages` unless that is `nil`), the common types those
  schemas use, then one section per catalog schema.

  The catalogs must be non-empty and share a protocol version.
  """
  @spec schema_prompt([Catalog.t()], [String.t()] | nil) ::
          {:ok, String.t()} | {:error, Error.t()}
  def schema_prompt(catalogs, allowed_messages \\ nil) do
    with {:ok, [first | _] = catalogs} <- check(catalogs) do
      version = Catalogs.protocol_version(first)
      a2r = Source.document(version, :agent_to_renderer) || %{}

      a2r =
        if allowed_messages, do: SchemaPruning.prune_messages(a2r, allowed_messages), else: a2r

      catalog_schemas = Enum.map(catalogs, &Catalog.to_schema/1)

      common =
        SchemaPruning.prune_common_types(
          Source.document(version, :common_types) || %{},
          catalog_schemas ++ [a2r]
        )

      sections =
        [@schema_start, "### Agent to Renderer Schema:\n#{compact(a2r)}"] ++
          if(map_size(common["$defs"] || %{}) > 0,
            do: ["### Common Types Schema:\n#{compact(common)}"],
            else: []
          ) ++
          Enum.map(catalog_schemas, &"### Catalog Schema:\n#{compact(&1)}") ++ [@schema_end]

      {:ok, Enum.join(sections, "\n\n")}
    end
  end

  defp check([]),
    do:
      {:error,
       Error.new(:catalog, "CATALOG_ERROR", "The schema prompt needs at least one catalog.")}

  defp check(catalogs) do
    case catalogs |> Enum.map(&Catalogs.protocol_version/1) |> Enum.uniq() |> Enum.sort() do
      [_one] ->
        {:ok, catalogs}

      versions ->
        {:error,
         Error.new(
           :catalog,
           "CATALOG_ERROR",
           "The schema prompt's catalogs target different protocol versions: #{inspect(versions)}."
         )}
    end
  end

  @doc """
  Each example turn as an `<a2ui-json>` block, separated by blank lines;
  `""` without examples.
  """
  @spec examples([[map()]] | nil) :: String.t()
  def examples(turns) when turns in [nil, []], do: ""

  def examples(turns) do
    Enum.map_join(turns, "\n\n", &"<a2ui-json>\n#{Parser.decompile(&1)}\n</a2ui-json>")
  end

  defp compact(schema), do: Jason.encode!(schema)
end

defmodule A2UIAgent.Express.Prompt do
  @moduledoc """
  The system prompt snippet of the Express format.

  The snippet has three parts, separated by blank lines:

    1. `## Workflow Description:` and the grammar rules (`base_rules/2`),
       with the rules for several catalogs when there are several;
    2. the positional signatures of each catalog's components and
       functions, and the catalog's own instructions, whose JSON
       examples are rewritten as Express (`catalog_instructions/2`);
    3. `### Examples:` and each example turn as an Express block
       (`examples/1`), when there are examples.

  An allowlist of message types (`:allowed_messages`) leaves out the
  rules for the statements that write other messages.
  """

  alias A2UIAgent.Express.{Catalogs, Decompiler, SchemaHelper}
  alias A2UICore.{Catalog, KeyOrder}

  @moduledoc since: "0.1.0"

  @rules ~S'''
  # A2UI Express DSL Output Contract

  You must output the user interface using A2UI Express.

  IMPORTANT: You MUST always surround the entire A2UI Express block with the sentinel tags `<a2ui>` and `</a2ui>`.

  The host compiler will compile your A2UI Express output into the correct JSON envelopes automatically.

  ## Grammar Rules

  1. Component constructors can be assigned to variables or nested inline inside parent component arguments:
     header = ComponentA(prop1="val1")
     root = ComponentB([header, ComponentC("Click", action=Event("submit"))])

     Keyword arguments (`param=value`) and positional arguments with `_` placeholders are supported.

     Variable names MUST start with a letter or underscore, and only contain letters, digits, and underscores.

  2. The interface tree must have a single entry point assigned to the reserved variable 'root'.

  3. Primitives:
     - Strings: Quoted with `"` or `"""`. Support for `\n`, `\t`, `\\`, and `\"` escapes.
       Raw Strings: Prefaced by `r` (e.g., `r"..."` or `r"""..."""`), with no escape processing.
     - Numbers: write as integers or decimals, e.g., 42
     - Booleans: write true or false
     - Null values: write null
     - Dates & Times: Values for date-time inputs (e.g. in DateTimeInput) must strictly use RFC 3339 format with a timezone offset (e.g. "2026-03-14T00:00:00Z").

  4. Lists: represent as arrays, e.g., [child1, child2].

  5. Maps: represent as key-value blocks, e.g., {title: "Overview", child: contentCol}. Map keys are always literal strings (dynamic variable resolution is not supported for keys).

  6. Data bindings: prefix absolute paths in the data model with '$', e.g., $/user/firstName.
     Prefix relative list scopes with '$', e.g., $firstName.
     A lone '$' represents an empty relative path which resolves to the root of the current context (e.g. inside a template, representing the entire item itself).

  7. Logic and validation: prefix client check rules with '?', e.g., ?required or ?regex("^[0-9]{5}$"). To specify a custom error message for validation failures, append it as an extra string argument, e.g. ?regex("^[0-9]{5}$", "Postal code must be 5 digits").

  8. Action events: represent server-side actions using the Event helper:
     Event("save_deal", {rep: $/form/rep})

  9. Nested functions: call client functions directly using catalog signatures, for example myFunction("value").

  10. Data model population: Assign a value directly to an absolute data path (e.g. $/path/to/key = "value") to populate or initialize values inside the shared dataModel. The value can be a primitive, array, or map.

  11. Dynamic list templates: If a component expects a template child list, represent it using the _template helper:
      _template($/path/to/list, itemTemplate)
      And define the template component variable on another line, utilizing relative path references prefixed with $:
      itemTemplate = Image($url)

  12. To delete a user interface surface, output the standalone `deleteSurface(surfaceId)` command (no variable assignment):
      deleteSurface("dashboard-surface-1")

  13. Static properties: Arguments annotated with '(static)' in the signatures below MUST be defined as literal values or arrays inline. You CANNOT use a dynamic data binding path (prefixed by $) for these arguments.

  14. Required actions: Parameters named 'action' (or annotated in component signatures) are strictly required. You must pass a valid Event (e.g. Event("click")) or function call. If no specific action is described in the user request, you must provide a dummy click event like Event("click") instead of passing null or omitting the parameter.

  15. Surface targeting: Output `surface(surfaceId)` to specify or target a user interface surface:
      surface("dashboard-surface-1")
      root = ComponentA(...)
  '''

  @root_example "root = ComponentA(...)"
  @example_keys ~w(createSurface updateComponents updateDataModel deleteSurface callFunction callRendererFunction)

  @doc """
  The grammar rules, exactly as the reference writes them when every
  message type is allowed.
  """
  @spec rules() :: String.t()
  def rules, do: String.trim_trailing(@rules, "\n")

  @doc """
  Assembles the prompt snippet for `catalogs`. Options: `:examples` (a
  list of turns, each a list of messages) and `:allowed_messages`.
  """
  @spec generate(Catalogs.t(), keyword()) :: {:ok, String.t()} | {:error, A2UICore.Error.t()}
  def generate(%Catalogs{} = catalogs, options \\ []) do
    with {:ok, examples} <- examples(catalogs, options[:examples]) do
      parts = [
        "## Workflow Description:\n" <> base_rules(catalogs, options[:allowed_messages]),
        catalog_instructions(catalogs)
      ]

      parts = if examples == "", do: parts, else: parts ++ ["### Examples:\n" <> examples]
      {:ok, Enum.join(parts, "\n\n")}
    end
  end

  @doc """
  The grammar rules. With an allowlist, the rules for statements that
  write other messages are left out and the rest renumbered. Rule 15's
  `root = ...` example names a component of the catalogs: the first one
  holding a single child reference, else the first one. With several
  catalogs, and components or data allowed, the rules for several
  catalogs follow.
  """
  @spec base_rules(Catalogs.t(), [String.t()] | nil) :: String.t()
  def base_rules(%Catalogs{} = catalogs, allowed_messages \\ nil) do
    base = if is_nil(allowed_messages), do: rules(), else: filter_rules(allowed_messages)

    base =
      case example_root_component(catalogs) do
        nil -> base
        name -> String.replace(base, @root_example, "root = #{name}(...)")
      end

    if length(catalogs.catalogs) <= 1 or not writes_surfaces?(allowed_messages),
      do: base,
      else: base <> "\n\n" <> multi_catalog_rules(catalogs)
  end

  defp writes_surfaces?(nil), do: true

  defp writes_surfaces?(allowed) do
    Enum.any?(
      ~w(createSurface CreateSurfaceMessage updateComponents UpdateComponentsMessage updateDataModel UpdateDataModelMessage),
      &(&1 in allowed)
    )
  end

  defp example_root_component(%Catalogs{helpers: helpers}) do
    Enum.find_value(helpers, &first_container/1) ||
      Enum.find_value(helpers, &List.first(&1.component_names))
  end

  defp first_container(helper),
    do: Enum.find(helper.component_names, &single_child?(helper.catalog, &1))

  defp single_child?(catalog, name) do
    spec = Catalog.ref_spec(catalog, name)
    spec != nil and Enum.any?(spec.single)
  end

  # The rules for the allowed message types, renumbered.
  defp filter_rules(allowed) do
    allows = fn names -> Enum.any?(names, &(&1 in allowed)) end
    creates = allows.(["createSurface", "CreateSurfaceMessage"])
    components = creates or allows.(["updateComponents", "UpdateComponentsMessage"])
    data = allows.(["updateDataModel", "UpdateDataModelMessage"])
    delete = allows.(["deleteSurface", "DeleteSurfaceMessage"])

    [contract, rules_block] = String.split(rules(), "## Grammar Rules\n\n", parts: 2)
    bodies = rule_bodies(rules_block)

    # Rule numbers (from 0) and whether they are kept: 0 components,
    # 1 root, 2..5 values, 6..8 calls, 9 data, 10 templates, 11 deletes,
    # 12..13 arguments; 14, surfaces, follows.
    groups = [
      {components, [0]},
      {creates, [1]},
      {true, 2..5},
      {components, 6..8},
      {data, [9]},
      {components, [10]},
      {delete, [11]},
      {components, 12..13}
    ]

    selected = for {true, numbers} <- groups, number <- numbers, do: elem(bodies, number)

    selected =
      if components or data,
        do: selected ++ [surface_rule(elem(bodies, 14), creates)],
        else: selected

    numbered = selected |> Enum.with_index(1) |> Enum.map(&number_rule/1)
    Enum.join(["#{contract}## Grammar Rules" | numbered], "\n\n")
  end

  # Each rule without its number and its indentation.
  defp rule_bodies(rules_block) do
    rules_block
    |> String.trim()
    |> String.split(~r/\n\n(?=\d+\. )/)
    |> Enum.map(fn rule ->
      rule
      |> String.replace(~r/\A\d+\. /, "")
      |> String.replace("\n   ", "\n")
      |> String.replace("\n    ", "\n ")
    end)
    |> List.to_tuple()
  end

  # Without components, the surface rule's `root = ...` line goes.
  defp surface_rule(rule, true), do: rule

  defp surface_rule(rule, false),
    do: rule |> String.split("\n") |> Enum.drop(-1) |> Enum.join("\n")

  defp number_rule({body, index}) do
    prefix = "#{index}. "
    indent = String.duplicate(" ", String.length(prefix))
    prefix <> Regex.replace(~r/\n(?!\n)/, body, "\n" <> indent)
  end

  defp multi_catalog_rules(%Catalogs{helpers: helpers} = catalogs) do
    ids = Enum.map(helpers, & &1.catalog_id)
    example = List.last(ids)

    rules = [
      "## Multiple Catalogs",
      "",
      "Several component catalogs are active. Each is identified by its catalog ID, and the " <>
        "signatures below are grouped by catalog:",
      Enum.map_join(ids, "\n", &"- `#{&1}`"),
      "",
      "16. A surface has no catalog of its own: do not name a catalog on a `surface` line. " <>
        "Each component and function call, including checks, actions, nested function calls " <>
        "and inline child components, is found by its name in whichever catalog defines it.",
      "",
      "17. When several catalogs define the same component or function name, you MUST say " <>
        "which one you mean: add a `catalogId` keyword argument to the component or function " <>
        "call, or a `{catalogId: ...}` argument to a check. Do not add `catalogId` to any " <>
        "other name:",
      ~s|    widget = ComponentName(..., catalogId="#{example}")|,
      ~s|    action = functionName(..., catalogId="#{example}")|,
      ~s|    ?checkName(..., {catalogId: "#{example}"})|
    ]

    shared =
      for {kind, label} <- [component: "Component", function: "Function"],
          name <- helpers |> Enum.flat_map(&names(&1, kind)) |> Enum.uniq() |> Enum.sort(),
          defining = Catalogs.defining(catalogs, kind, name),
          length(defining) > 1 do
        "- #{label} `#{name}`: " <> Enum.map_join(defining, ", ", &"`#{&1}`")
      end

    rules =
      if shared == [],
        do: rules,
        else:
          rules ++
            ["", "These names are defined in several catalogs and need a `catalogId`:"] ++ shared

    Enum.join(rules, "\n")
  end

  defp names(helper, :component), do: helper.component_names
  defp names(helper, :function), do: helper.function_names

  @doc """
  The signatures and instructions of one catalog (given by id), or of
  all of them: with several catalogs, each under a `# Catalog` heading.
  """
  @spec catalog_instructions(Catalogs.t(), String.t() | nil) :: String.t()
  def catalog_instructions(%Catalogs{} = catalogs, catalog_id \\ nil) do
    cond do
      catalog_id ->
        case Catalogs.helper(catalogs, catalog_id) do
          nil -> ""
          helper -> catalog_description(catalogs, helper)
        end

      length(catalogs.helpers) <= 1 ->
        catalog_description(catalogs, Catalogs.first_helper(catalogs))

      true ->
        Enum.map_join(catalogs.helpers, "\n\n", fn helper ->
          "# Catalog `#{helper.catalog_id}`\n\n" <> catalog_description(catalogs, helper)
        end)
    end
  end

  defp catalog_description(catalogs, helper) do
    instructions =
      case KeyOrder.get(helper.document, "instructions") do
        text when is_binary(text) and text != "" ->
          "\n\n## Catalog Instructions\n\n" <>
            translate_examples(catalogs, text, helper.catalog_id)

        _none ->
          ""
      end

    "## Positional Component Signatures\n\nUse these exact positional signatures to " <>
      "instantiate components. Do not output property keys:\n" <>
      component_signatures(helper) <>
      "\n\n## Positional Function Signatures\n\nUse these exact positional signatures to " <>
      "instantiate check rules or logic functions:\n" <>
      function_signatures(helper) <> instructions
  end

  # A fenced JSON example of messages becomes a fenced Express block.
  defp translate_examples(catalogs, text, catalog_id) do
    Regex.replace(~r/```json\s*\n(.*?)\n```/s, text, fn whole, json ->
      case decompile_example(catalogs, String.trim(json), catalog_id) do
        {:ok, express} -> "```\n" <> Decompiler.wrap_decompiled_blocks([express]) <> "\n```"
        :error -> whole
      end
    end)
  end

  defp decompile_example(catalogs, json, catalog_id) do
    with {:ok, parsed} <- Jason.decode(json, objects: :ordered_objects),
         [_ | _] = messages <- if(is_list(parsed), do: parsed, else: [parsed]),
         true <- Enum.all?(messages, &example_message?/1),
         normalized = normalize_examples(messages, catalogs.version, catalog_id),
         {:ok, express} <- Decompiler.decompile(catalogs, normalized) do
      {:ok, express}
    else
      _not_messages -> :error
    end
  end

  defp example_message?(message),
    do: is_map(message) and Enum.any?(@example_keys, &KeyOrder.has_key?(message, &1))

  @doc false
  # Fills in what catalog examples usually leave out: the version, the
  # surface (`main`), a create's catalog, and a top-level `callFunction`
  # as a `callRendererFunction`.
  @spec normalize_examples([term()], String.t(), String.t() | nil) :: [term()]
  def normalize_examples(messages, version, catalog_id) do
    Enum.map(messages, fn message ->
      message
      |> normalize_version(version)
      |> normalize_surfaces(catalog_id)
      |> normalize_call(catalog_id)
    end)
  end

  defp normalize_version(message, version) do
    case KeyOrder.get(message, "version") do
      nil ->
        if Enum.any?(@example_keys, &KeyOrder.has_key?(message, &1)),
          do: put(message, "version", version),
          else: message

      value ->
        text = to_string(value)
        if text =~ ~r/\A\d/, do: put(message, "version", "v" <> text), else: message
    end
  end

  defp normalize_surfaces(message, catalog_id) do
    Enum.reduce(~w(createSurface updateComponents updateDataModel deleteSurface), message, fn
      key, message ->
        case KeyOrder.get(message, key) do
          body when is_map(body) -> put(message, key, normalize_body(key, body, catalog_id))
          _other -> message
        end
    end)
  end

  defp normalize_body(key, body, catalog_id) do
    body = if KeyOrder.has_key?(body, "surfaceId"), do: body, else: put(body, "surfaceId", "main")

    if key == "createSurface" and KeyOrder.get(body, "catalogId") in [nil, ""] and
         catalog_id != nil,
       do: put(body, "catalogId", catalog_id),
       else: body
  end

  defp normalize_call(message, catalog_id) do
    call = KeyOrder.get(message, "callFunction")

    if is_map(call) and not KeyOrder.has_key?(message, "callRendererFunction") do
      call =
        if catalog_id && not KeyOrder.has_key?(call, "catalogId"),
          do: put(call, "catalogId", catalog_id),
          else: call

      call_id = to_string(KeyOrder.get(message, "functionCallId") || "call_1")

      message
      |> delete(["callFunction", "functionCallId"])
      |> put("callRendererFunction", %{"functionCallId" => call_id, "callFunction" => call})
    else
      message
    end
  end

  defp put(%Jason.OrderedObject{} = node, key, value), do: KeyOrder.put(node, key, value)
  defp put(%{} = node, key, value), do: Map.put(node, key, value)

  defp delete(%Jason.OrderedObject{values: values} = node, keys),
    do: %{node | values: Enum.reject(values, fn {key, _} -> key in keys end)}

  defp delete(%{} = node, keys), do: Map.drop(node, keys)

  @doc """
  The example turns as Express blocks, separated by blank lines. An
  example the catalogs cannot express is an error.
  """
  @spec examples(Catalogs.t(), [[map()]] | nil) ::
          {:ok, String.t()} | {:error, A2UICore.Error.t()}
  def examples(_catalogs, nil), do: {:ok, ""}
  def examples(_catalogs, []), do: {:ok, ""}

  def examples(%Catalogs{} = catalogs, turns) do
    turns
    |> Enum.reduce_while({:ok, []}, fn turn, {:ok, blocks} ->
      case Decompiler.decompile(catalogs, turn) do
        {:ok, express} -> {:cont, {:ok, [Decompiler.wrap_decompiled_blocks([express]) | blocks]}}
        {:error, error} -> {:halt, {:error, error}}
      end
    end)
    |> case do
      {:ok, blocks} -> {:ok, blocks |> Enum.reverse() |> Enum.join("\n\n")}
      error -> error
    end
  end

  # -- signatures ----------------------------------------------------------------------

  @doc false
  @spec component_signatures(SchemaHelper.t()) :: String.t()
  def component_signatures(helper) do
    helper.component_names
    |> Enum.sort()
    |> Enum.map_join("\n", &component_signature(helper, &1))
  end

  defp component_signature(helper, name) do
    required = SchemaHelper.component_required(helper, name)

    {labels, details} =
      helper
      |> SchemaHelper.component_properties(name)
      |> Enum.map(fn property ->
        schema = SchemaHelper.property_schema(helper, name, property)

        {argument_label(property, property in required, schema),
         property_details(property, schema)}
      end)
      |> Enum.unzip()

    signature(
      name,
      labels,
      SchemaHelper.component_description(helper, name),
      Enum.reject(details, &is_nil/1)
    )
  end

  defp argument_label(property, required?, schema) do
    label = property <> if(required?, do: "", else: "?")
    ref = if is_map(schema), do: KeyOrder.get(schema, "$ref")

    cond do
      is_binary(ref) and String.contains?(ref, "ComponentId") -> label <> " (component ID)"
      not allows_binding?(schema) -> label <> " (static)"
      true -> label
    end
  end

  defp allows_binding?(schema) when is_map(schema) do
    ref = KeyOrder.get(schema, "$ref")

    (is_binary(ref) and String.contains?(ref, ["DataBinding", "Dynamic", "ChildList"])) or
      Enum.any?(["oneOf", "anyOf", "allOf"], fn key ->
        schema |> KeyOrder.get(key) |> List.wrap() |> Enum.any?(&allows_binding?/1)
      end)
  end

  defp allows_binding?(_schema), do: false

  defp property_details(property, schema) when is_map(schema) do
    description = KeyOrder.get(schema, "description")
    enum = schema_enum(schema)

    line =
      case Enum.reject(
             [description, enum && "Must be one of: " <> Enum.map_join(enum, ", ", &"'#{&1}'")],
             &is_nil/1
           ) do
        [] -> nil
        parts -> "  - #{property}: " <> Enum.join(parts, " ")
      end

    case {KeyOrder.get(schema, "type"), sub_keys(schema)} do
      {_type, nil} -> line
      {"object", keys} when is_nil(line) -> "  - #{property}: Map with keys:\n" <> keys
      {"object", keys} -> line <> "\n    Map keys:\n" <> keys
      {"array", keys} when is_nil(line) -> "  - #{property}: List of maps with keys:\n" <> keys
      {"array", keys} -> line <> "\n    List of maps keys:\n" <> keys
    end
  end

  defp property_details(_property, _schema), do: nil

  # The keys of an object property, or of the objects an array holds.
  defp sub_keys(schema) do
    case KeyOrder.get(schema, "type") do
      "object" ->
        key_lines(KeyOrder.get(schema, "properties"))

      "array" ->
        items = KeyOrder.get(schema, "items")

        if is_map(items) and KeyOrder.get(items, "type") == "object",
          do: key_lines(KeyOrder.get(items, "properties"))

      _other ->
        nil
    end
  end

  defp key_lines(properties) when is_map(properties) do
    Enum.map_join(SchemaHelper.pairs(properties), "\n", fn {key, sub} ->
      case KeyOrder.get(sub, "description") do
        description when is_binary(description) and description != "" ->
          "    * #{key} - #{description}"

        _none ->
          "    * #{key}"
      end
    end)
  end

  defp key_lines(_properties), do: nil

  defp schema_enum(schema) when is_map(schema) do
    case KeyOrder.get(schema, "enum") do
      values when is_list(values) ->
        Enum.map(values, &py_str/1)

      _none ->
        ["oneOf", "anyOf"]
        |> Enum.flat_map(&List.wrap(KeyOrder.get(schema, &1)))
        |> Enum.find_value(&schema_enum/1)
    end
  end

  defp schema_enum(_schema), do: nil

  defp py_str(true), do: "True"
  defp py_str(false), do: "False"
  defp py_str(nil), do: "None"
  defp py_str(value) when is_number(value), do: Decompiler.number(value)
  defp py_str(value) when is_binary(value), do: value
  defp py_str(value), do: inspect(value)

  @doc false
  @spec function_signatures(SchemaHelper.t()) :: String.t()
  def function_signatures(helper) do
    helper.function_names
    |> Enum.sort()
    |> Enum.map_join("\n", &function_signature(helper, &1))
  end

  defp function_signature(helper, name) do
    required = SchemaHelper.function_required(helper, name)

    arg_schemas =
      helper.functions
      |> Map.get(name)
      |> KeyOrder.get("properties")
      |> KeyOrder.get("args")
      |> KeyOrder.get("properties")

    {labels, details} =
      helper
      |> SchemaHelper.function_properties(name)
      |> Enum.map(fn parameter ->
        description = arg_schemas |> KeyOrder.get(parameter) |> KeyOrder.get("description")

        detail =
          if is_binary(description) and description != "", do: "  - #{parameter}: #{description}"

        {parameter <> if(parameter in required, do: "", else: "?"), detail}
      end)
      |> Enum.unzip()

    signature(
      name,
      labels,
      SchemaHelper.function_description(helper, name),
      Enum.reject(details, &is_nil/1)
    )
  end

  defp signature(name, labels, description, details) do
    signature = "• #{name}(#{Enum.join(labels, ", ")})"

    signature =
      if is_binary(description) and description != "",
        do: signature <> "\n  - Description: " <> String.replace(description, "\n", "\n    "),
        else: signature

    if details == [], do: signature, else: signature <> "\n" <> Enum.join(details, "\n")
  end
end

defmodule A2UIAgent.Macro do
  @moduledoc """
  A macro: a component the model can write that the agent expands into
  components of its catalog before they reach the renderer.

      import A2UIAgent.Builder.Basic

      status_badge =
        A2UIAgent.Macro.new(
          "StatusBadge",
          [status: :string, title: :string],
          fn %{status: status, title: title} ->
            card(
              child:
                row(
                  children: [
                    text(text: String.upcase(status), variant: "caption"),
                    text(text: title, variant: "h3")
                  ]
                )
            )
          end,
          description: "A status badge."
        )

  The model writes `{"id": "badge", "component": "StatusBadge",
  "status": "active", "title": "Server 1"}`; `A2UIAgent.MacroExpander`
  replaces it with the flattened tree, rooted at `badge`. The macro's
  catalog schema (`to_json_schema/2`) is derived from its parameters.

  ## Parameters

  Parameters are a keyword list of names and types, in order. A type can
  also be given with options, `title: [type: :string, description:
  "..."]`: `:description` (default: the name, spaced and capitalized),
  `:required` (default `true` unless a `:default` is given) and
  `:default`, passed for an optional parameter left out. Types:

    * `:string`, `:integer`, `:number`, `:boolean`, `:object`, `:any`,
      `{:enum, values}` and `{:list, type}`;
    * `:component`, a child slot: the model passes a component id, which
      reaches the function as an `A2UIAgent.Builder.ref/1`;
    * `:component_list`, child slots: a list of ids, as refs;
    * `:action`: an event name, an event (`{"name": ..., "context": ...}`)
      or an action, as an action;
    * `:dynamic_string`, `:dynamic_number`, `:dynamic_boolean`,
      `:dynamic_string_list`, `:dynamic_value`, `:data_binding`,
      `:function_call`, `:check_rule` and `:accessibility`: the
      protocol's common types.

  Any argument written as a binding (`{"path": ...}`) reaches the
  function as an `A2UIAgent.Builder.bind/1`.

  The function gets a map of the arguments by parameter name and returns
  a component tree. It may call other macros with `call/2`.
  """

  alias A2UIAgent.Builder
  alias A2UIAgent.Builder.{Component, Ref}
  alias A2UICore.KeyOrder

  @moduledoc since: "0.1.0"

  @enforce_keys [:name, :fun]
  defstruct [:name, :fun, :description, parameters: []]

  @type type ::
          :string
          | :integer
          | :number
          | :boolean
          | :object
          | :any
          | {:enum, [term()]}
          | {:list, type()}
          | :component
          | :component_list
          | :action
          | :dynamic_string
          | :dynamic_number
          | :dynamic_boolean
          | :dynamic_string_list
          | :dynamic_value
          | :data_binding
          | :function_call
          | :check_rule
          | :accessibility

  @type parameter :: %{
          name: atom(),
          type: type(),
          required: boolean(),
          default: term(),
          description: String.t()
        }

  @type t :: %__MODULE__{
          name: String.t(),
          fun: (map() -> Builder.tree()),
          description: String.t() | nil,
          parameters: [parameter()]
        }

  defmodule Call do
    @moduledoc """
    A macro call inside a component tree, expanded where the tree is
    flattened. Made by `A2UIAgent.Macro.call/2`.
    """

    @moduledoc since: "0.1.0"

    @enforce_keys [:macro]
    defstruct [:macro, args: %{}]

    @type t :: %__MODULE__{macro: A2UIAgent.Macro.t() | String.t(), args: keyword() | map()}
  end

  @ref_prefix "common_types.json#/$defs/"
  @simple_types [:string, :integer, :number, :boolean, :object, :any]
  @slot_types [:component, :component_list]
  @common_types %{
    action: "Action",
    dynamic_string: "DynamicString",
    dynamic_number: "DynamicNumber",
    dynamic_boolean: "DynamicBoolean",
    dynamic_string_list: "DynamicStringList",
    dynamic_value: "DynamicValue",
    data_binding: "DataBinding",
    function_call: "FunctionCall",
    check_rule: "CheckRule",
    accessibility: "AccessibilityAttributes"
  }

  @doc """
  Defines a macro named `name` (the component name the model writes).
  Option: `:description`, the component's description in the catalog.

  Raises `ArgumentError` for a parameter with an unknown type.
  """
  @spec new(String.t(), keyword(), (map() -> Builder.tree()), keyword()) :: t()
  def new(name, parameters, fun, options \\ [])
      when is_binary(name) and is_list(parameters) and is_function(fun, 1) do
    %__MODULE__{
      name: name,
      fun: fun,
      description: options[:description],
      parameters: Enum.map(parameters, &parameter/1)
    }
  end

  defp parameter({name, spec}) when is_atom(name) do
    {type, options} =
      if Keyword.keyword?(spec) and Keyword.has_key?(spec, :type),
        do: Keyword.pop!(spec, :type),
        else: {spec, []}

    type = check_type!(type)

    %{
      name: name,
      type: type,
      required: Keyword.get(options, :required, not Keyword.has_key?(options, :default)),
      default: options[:default],
      description: options[:description] || default_description(name)
    }
  end

  defp parameter(other),
    do: raise(ArgumentError, "expected a parameter as `name: type`, got: #{inspect(other)}")

  defp check_type!({:list, :component}), do: :component_list
  defp check_type!({:list, type}), do: {:list, check_type!(type)}
  defp check_type!({:enum, values} = type) when is_list(values) and values != [], do: type

  defp check_type!(type) when type in @simple_types or type in @slot_types, do: type
  defp check_type!(type) when is_map_key(@common_types, type), do: type

  defp check_type!(type),
    do: raise(ArgumentError, "unknown macro parameter type: #{inspect(type)}")

  # Python's `name.replace("_", " ").capitalize()`.
  defp default_description(name) do
    {first, rest} = name |> Atom.to_string() |> String.replace("_", " ") |> String.split_at(1)
    String.upcase(first) <> String.downcase(rest)
  end

  @doc """
  The macro's component schema for a catalog: an object whose properties
  are the parameters, with references to the protocol's common types
  under `ref_prefix`.

      iex> macro = A2UIAgent.Macro.new("Badge", [label: :dynamic_string], fn _ -> nil end)
      iex> A2UIAgent.Macro.to_json_schema(macro)
      %{
        "type" => "object",
        "properties" => %{
          "label" => %{"$ref" => "common_types.json#/$defs/DynamicString", "description" => "Label"}
        },
        "required" => ["label"]
      }
  """
  @spec to_json_schema(t(), String.t()) :: map()
  def to_json_schema(%__MODULE__{} = macro, ref_prefix \\ @ref_prefix),
    do: macro |> ordered_json_schema(ref_prefix) |> KeyOrder.to_plain()

  @doc false
  # The same schema as `Jason.OrderedObject`s, with the properties in
  # parameter order, for a catalog document.
  @spec ordered_json_schema(t(), String.t()) :: Jason.OrderedObject.t()
  def ordered_json_schema(%__MODULE__{} = macro, ref_prefix \\ @ref_prefix) do
    properties =
      for parameter <- macro.parameters do
        {Atom.to_string(parameter.name),
         KeyOrder.new(type_schema(parameter.type, parameter.description, ref_prefix))}
      end

    required = for %{required: true, name: name} <- macro.parameters, do: Atom.to_string(name)

    KeyOrder.new(
      [{"type", "object"}, {"properties", KeyOrder.new(properties)}] ++
        if(required == [], do: [], else: [{"required", required}]) ++
        if(macro.description, do: [{"description", macro.description}], else: [])
    )
  end

  defp type_schema(type, description, prefix),
    do: bare_schema(type, prefix) ++ [{"description", description}]

  defp bare_schema(:string, _prefix), do: [{"type", "string"}]
  defp bare_schema(:integer, _prefix), do: [{"type", "integer"}]
  defp bare_schema(:number, _prefix), do: [{"type", "number"}]
  defp bare_schema(:boolean, _prefix), do: [{"type", "boolean"}]
  defp bare_schema(:object, _prefix), do: [{"type", "object"}]
  defp bare_schema(:any, _prefix), do: []
  defp bare_schema(:component, prefix), do: [{"$ref", prefix <> "ComponentId"}]
  defp bare_schema(:component_list, prefix), do: [{"$ref", prefix <> "ChildList"}]

  defp bare_schema({:list, type}, prefix),
    do: [{"type", "array"}, {"items", KeyOrder.new(bare_schema(type, prefix))}]

  defp bare_schema({:enum, values}, _prefix) do
    cond do
      Enum.all?(values, &is_binary/1) -> [{"type", "string"}, {"enum", values}]
      Enum.all?(values, &is_number/1) -> [{"type", "number"}, {"enum", values}]
      true -> [{"enum", values}]
    end
  end

  defp bare_schema(type, prefix), do: [{"$ref", prefix <> Map.fetch!(@common_types, type)}]

  @doc """
  A call of `macro` (a macro, or the name of one the flattening is given
  with `:macros`) inside a tree. The call expands where the tree is
  flattened, in the tree's scope: the components it makes are named
  after the tree's root.
  """
  @spec call(t() | String.t(), keyword() | map()) :: Call.t()
  def call(macro, args \\ %{}) when is_struct(macro, __MODULE__) or is_binary(macro),
    do: %Call{macro: macro, args: args}

  @doc """
  Runs the macro with `args` (by parameter name, as atoms or strings)
  and returns its tree. Arguments are coerced as the parameters' types
  say (see "Parameters"); a left-out optional parameter gets its
  default.

  Raises `ArgumentError` for an unknown or missing argument, or when the
  function does not return a component tree.
  """
  @spec build(t(), keyword() | map()) :: Builder.tree()
  def build(%__MODULE__{} = macro, args) do
    given = Map.new(args, fn {key, value} -> {to_string(key), value} end)
    names = MapSet.new(macro.parameters, &Atom.to_string(&1.name))

    case Enum.reject(Map.keys(given), &MapSet.member?(names, &1)) do
      [] ->
        :ok

      unknown ->
        raise ArgumentError, "macro #{macro.name} has no parameter #{Enum.join(unknown, ", ")}"
    end

    arguments =
      Map.new(macro.parameters, fn parameter ->
        key = Atom.to_string(parameter.name)

        case Map.fetch(given, key) do
          {:ok, value} ->
            {parameter.name, coerce(parameter.type, value)}

          :error when parameter.required ->
            raise ArgumentError, "macro #{macro.name} is missing the argument #{key}"

          :error ->
            {parameter.name, parameter.default}
        end
      end)

    macro.fun.(arguments) |> check_tree!(macro)
  end

  defp check_tree!(%Component{} = tree, _macro), do: tree
  defp check_tree!(%Ref{} = tree, _macro), do: tree
  defp check_tree!(%Call{} = tree, _macro), do: tree

  defp check_tree!(trees, macro) when is_list(trees),
    do: Enum.map(trees, &check_tree!(&1, macro))

  defp check_tree!(other, macro),
    do:
      raise(
        ArgumentError,
        "macro #{macro.name} must return a component tree, got: #{inspect(other)}"
      )

  @doc false
  # How a model's argument reaches the macro's function.
  @spec coerce(type(), term()) :: term()
  def coerce(:component, id) when is_binary(id), do: Builder.ref(id)

  def coerce(:component_list, items) when is_list(items),
    do: Enum.map(items, fn item -> if is_binary(item), do: Builder.ref(item), else: item end)

  def coerce(type, value) do
    case binding_path(value) do
      nil -> coerce_value(type, value)
      path -> Builder.bind(path)
    end
  end

  defp coerce_value(:action, name) when is_binary(name), do: Builder.event(name)

  defp coerce_value(:action, %{} = action) when not is_struct(action) do
    case action do
      %{"event" => name} when is_binary(name) -> Builder.event(name)
      %{"event" => _} -> action
      %{"functionCall" => _} -> action
      %{"function_call" => call} -> %{"functionCall" => call}
      event -> %{"event" => event}
    end
  end

  defp coerce_value(_type, value), do: value

  defp binding_path(%{} = map) when map_size(map) == 1 and not is_struct(map) do
    case Map.to_list(map) do
      [{key, path}] when key in ["path", "@path"] and is_binary(path) -> path
      _other -> nil
    end
  end

  defp binding_path(_value), do: nil
end

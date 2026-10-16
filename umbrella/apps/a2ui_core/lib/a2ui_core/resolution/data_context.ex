defmodule A2UICore.Resolution.DataContext do
  @moduledoc """
  A data-binding scope: the absolute path relative bindings resolve
  against, the collection-template iteration index, and — when built
  for a surface — what is needed to evaluate dynamic values.

  The root scope is `"/"`. A component rendered for item `2` of a
  `/items` template runs in the nested scope `"/items/2/"`, so its
  relative path `name` resolves to `/items/2/name`.

  ## Path resolution

  Follows the reference:

    * an absolute path (starting with `/`) is returned unchanged,
    * `""` and `"."` resolve to the scope itself,
    * any other path is joined to the scope, ignoring trailing slashes
      on the scope.

      iex> ctx = A2UICore.Resolution.DataContext.new("/user")
      iex> A2UICore.Resolution.DataContext.resolve_path(ctx, "name")
      "/user/name"
      iex> A2UICore.Resolution.DataContext.resolve_path(ctx, "/other")
      "/other"
      iex> A2UICore.Resolution.DataContext.resolve_path(ctx, ".")
      "/user"

  ## Dynamic values

  `resolve_dynamic_value/2` evaluates a literal, a data binding
  (`{"path": …}` in v0.9, `{"@path": …}` in v1.0) or a function call
  (`{"call": …, "args": …}` / `{"@call": …, "args": …}`, optionally with
  a `catalogId`) against the data model, recursing through arrays and
  objects. It never raises: what the reference reports through the
  surface comes back as *effects* next to the value —

    * `{:warning, %{code: "MISSING_DATA_BINDING", path: …, message: …}}`
      when a bound path is absent (once per path per call),
    * `{:error, %{code: "EXPRESSION_ERROR", message: …, expression: …}}`
      when a function call fails; the call's value is then `nil`.

  A function can ask for more through its effects — the MCP catalog's
  functions do (`A2UICore.Functions.MCP`):

    * `{:write, %{path: path, value: value}}` — write the data model;
    * `{:messages, %{messages: messages, source: :resource | :inline}}` —
      apply A2UI messages.

  They come back in evaluation order. A renderer applies them when they
  come from an action (`A2UICore.Resolution.NodeResolver.invoke/5`);
  rendering ignores them.

  v1.0 objects follow the reserved-key rule
  (`A2UICore.Validation.ReservedKeys`): `@@x` is the literal key `@x`,
  any other single-`@` key is an `INVALID_RESERVED_KEY` error.
  """

  alias A2UICore.{Catalog, SemVer}
  alias A2UICore.Functions.System
  alias A2UICore.State.{DataModel, Surface}
  alias A2UICore.Validation.{Payload, ReservedKeys}

  @moduledoc since: "0.1.0"

  defstruct path: "/",
            index: nil,
            parent: nil,
            data_model: nil,
            catalog: nil,
            catalogs: %{},
            protocol_version: nil,
            surface_id: nil,
            locale: nil

  @type t :: %__MODULE__{
          path: String.t(),
          index: non_neg_integer() | nil,
          parent: t() | nil,
          data_model: DataModel.t() | nil,
          catalog: Catalog.t() | nil,
          catalogs: %{optional(String.t()) => Catalog.t()},
          protocol_version: String.t() | nil,
          surface_id: String.t() | nil,
          locale: String.t() | nil
        }

  @typedoc "A warning or error produced while resolving, or what a function asks for."
  @type effect :: {:warning, map()} | {:error, map()} | {:write, map()} | {:messages, map()}

  @max_function_args Payload.max_function_call_args()

  @doc """
  Creates a root scope at `path` (default `"/"`). The stored path always
  ends with a slash.

  Options: `:data_model`, `:catalog` (the default catalog, if any),
  `:catalogs` (`%{catalog_id => catalog}` reachable by `catalogId`),
  `:protocol_version` (default: the default catalog's), `:surface_id`
  (for messages), `:locale`.
  """
  @spec new(String.t(), keyword()) :: t()
  def new(path \\ "/", options \\ []) when is_binary(path) do
    catalog = options[:catalog]

    %__MODULE__{
      path: with_trailing_slash(path),
      data_model: options[:data_model],
      catalog: catalog,
      catalogs: Keyword.get(options, :catalogs, %{}),
      protocol_version: options[:protocol_version] || (catalog && catalog.protocol_version),
      surface_id: options[:surface_id],
      locale: options[:locale]
    }
  end

  @doc """
  Creates the root scope for a `A2UICore.State.Surface`: its data
  model, its default catalog and the catalogs it can reach.
  """
  @spec for_surface(Surface.t(), keyword()) :: t()
  def for_surface(%Surface{} = surface, options \\ []) do
    new(
      Keyword.get(options, :path, "/"),
      data_model: surface.data_model,
      catalog: Surface.default_catalog(surface),
      catalogs: surface.catalogs,
      protocol_version: Surface.protocol_version(surface),
      surface_id: surface.id,
      locale: Keyword.get(options, :locale, surface.metadata[:locale])
    )
  end

  @doc """
  Creates a child scope for `relative_path` (a leading `/` is ignored),
  optionally recording the iteration `index` of a collection template.
  """
  @spec nested(t(), String.t(), non_neg_integer() | nil) :: t()
  def nested(%__MODULE__{} = context, relative_path, index \\ nil)
      when is_binary(relative_path) do
    relative = String.replace_prefix(relative_path, "/", "")

    %__MODULE__{
      context
      | path: with_trailing_slash(context.path <> relative),
        index: index,
        parent: context
    }
  end

  @doc """
  The active collection index: the nearest scope's recorded index, or
  the numeric last segment of its path, walking outward; `nil` outside a
  collection.

      iex> root = A2UICore.Resolution.DataContext.new()
      iex> item = A2UICore.Resolution.DataContext.nested(root, "items/3")
      iex> A2UICore.Resolution.DataContext.index(item)
      3
      iex> A2UICore.Resolution.DataContext.index(root)
      nil
  """
  @spec index(t()) :: non_neg_integer() | nil
  def index(%__MODULE__{index: index}) when is_integer(index), do: index

  def index(%__MODULE__{path: path, parent: parent}) do
    last = path |> String.split("/", trim: true) |> List.last()

    cond do
      is_binary(last) and Regex.match?(~r/\A[0-9]+\z/, last) -> String.to_integer(last)
      parent != nil -> index(parent)
      true -> nil
    end
  end

  @doc """
  Resolves `path` against the scope to an absolute pointer.
  """
  @spec resolve_path(t(), String.t()) :: String.t()
  def resolve_path(%__MODULE__{}, "/" <> _ = absolute), do: absolute

  def resolve_path(%__MODULE__{path: path}, relative) when relative in ["", "."] do
    case String.trim_trailing(path, "/") do
      "" -> "/"
      base -> base
    end
  end

  def resolve_path(%__MODULE__{path: path}, relative) when is_binary(relative),
    do: String.trim_trailing(path, "/") <> "/" <> relative

  @doc """
  Whether bindings use the v1.0 `@path`/`@call` spelling, decided by
  the scope's protocol version (that of its surface, which outlives a
  missing default catalog).
  """
  @spec v1?(t()) :: boolean()
  def v1?(%__MODULE__{protocol_version: version}) when is_binary(version),
    do: SemVer.at_least(version, "v1.0")

  def v1?(%__MODULE__{}), do: false

  @doc """
  Evaluates a dynamic value; see the module documentation.
  """
  @spec resolve_dynamic_value(t(), term()) :: {term(), [effect()]}
  def resolve_dynamic_value(%__MODULE__{} = context, value) do
    {resolved, effects} = resolve(context, value, [])
    {resolved, effects |> Enum.reverse() |> dedupe_warnings()}
  end

  @doc """
  Resolves an action's dynamic parts: an event's `context` and
  `userMessage`, a plain action object, or a function call.
  """
  @spec resolve_action(t(), term()) :: {term(), [effect()]}
  def resolve_action(%__MODULE__{} = context, %{"event" => %{} = event} = action) do
    {event, effects} = resolve_action_parts(context, event)
    {%{action | "event" => event}, effects}
  end

  def resolve_action(%__MODULE__{} = context, %{"name" => _} = action),
    do: resolve_action_parts(context, action)

  def resolve_action(%__MODULE__{} = context, %{"functionCall" => call}),
    do: resolve_dynamic_value(context, call)

  def resolve_action(%__MODULE__{} = context, %{} = action) do
    if is_binary(action["@call"]) or is_binary(action["call"]) do
      resolve_dynamic_value(context, action)
    else
      {action, []}
    end
  end

  def resolve_action(%__MODULE__{}, action), do: {action, []}

  defp resolve_action_parts(context, parts) do
    {parts, effects} =
      case parts do
        %{"context" => action_context} -> resolve_action_context(context, parts, action_context)
        _no_context -> {parts, []}
      end

    case parts do
      %{"userMessage" => message} when not is_nil(message) ->
        {resolved, more} = resolve_dynamic_value(context, message)
        {Map.put(parts, "userMessage", resolved), effects ++ more}

      _no_message ->
        {parts, effects}
    end
  end

  defp resolve_action_context(context, parts, action_context) when is_map(action_context) do
    {resolved, effects} =
      Enum.reduce(action_context, {%{}, []}, fn {key, value}, {acc, effects} ->
        {resolved, found} = resolve_dynamic_value(context, value)
        {Map.put(acc, key, resolved), effects ++ found}
      end)

    {Map.put(parts, "context", resolved), effects}
  end

  defp resolve_action_context(_context, parts, _other), do: {Map.put(parts, "context", %{}), []}

  # -- evaluation ---------------------------------------------------------------

  defp resolve(_context, nil, effects), do: {nil, effects}

  defp resolve(context, %{} = value, effects) do
    v1? = v1?(context)

    cond do
      not Map.has_key?(value, "componentId") and is_binary(path_of(value, v1?)) ->
        read_binding(context, path_of(value, v1?), effects)

      is_binary(call_of(value, v1?)) ->
        call_function(context, value, call_of(value, v1?), effects)

      true ->
        resolve_object(context, value, v1?, effects)
    end
  end

  defp resolve(context, list, effects) when is_list(list) do
    {items, effects} =
      Enum.map_reduce(list, effects, fn item, effects -> resolve(context, item, effects) end)

    {items, effects}
  end

  defp resolve(_context, literal, effects), do: {literal, effects}

  defp path_of(value, true), do: value["@path"]
  defp path_of(value, false), do: value["path"]

  defp call_of(value, true), do: value["@call"]
  defp call_of(value, false), do: value["call"]

  defp read_binding(context, binding, effects) do
    path = resolve_path(context, binding)

    case context.data_model do
      nil -> {nil, effects}
      model -> lookup_binding(model, path, effects)
    end
  end

  defp lookup_binding(model, path, effects) do
    with {:ok, present?} <- DataModel.has_path?(model, path),
         {:ok, value} <- DataModel.get(model, path) do
      {value, if(present?, do: effects, else: [missing_binding(path) | effects])}
    else
      {:error, error} -> {nil, [{:error, error_payload(error, path)} | effects]}
    end
  end

  defp resolve_object(context, object, v1?, effects) do
    case check_reserved(context, object, v1?) do
      :ok -> resolve_entries(context, object, v1?, effects)
      {:error, error} -> {nil, [{:error, error_payload(error, nil)} | effects]}
    end
  end

  defp check_reserved(_context, _object, false), do: :ok

  defp check_reserved(context, object, true),
    do: ReservedKeys.check(Map.keys(object), context.protocol_version)

  defp resolve_entries(context, object, v1?, effects) do
    Enum.reduce(object, {%{}, effects}, fn {key, value}, {acc, effects} ->
      {resolved, effects} = resolve(context, value, effects)
      {Map.put(acc, output_key(key, v1?), resolved), effects}
    end)
  end

  defp output_key(key, true), do: ReservedKeys.unescape(key)
  defp output_key(key, false), do: key

  defp call_function(context, value, name, effects) do
    raw_args = Map.get(value, "args", %{})

    case execute(context, name, raw_args, call_catalog(context, value)) do
      {:ok, result, found} -> {result, Enum.reverse(found) ++ effects}
      {:error, payload, found} -> {nil, [{:error, payload} | Enum.reverse(found) ++ effects]}
    end
  end

  # The catalog a call names: from v1.0 `{:named, id}` whenever it carries
  # a `catalogId` key (an empty one names a catalog too), else `:default`.
  # Before v1.0 a call always runs in the surface catalog.
  defp call_catalog(context, value) do
    cond do
      not v1?(context) -> :default
      Map.has_key?(value, "catalogId") -> {:named, value["catalogId"]}
      Map.has_key?(value, "catalog_id") -> {:named, value["catalog_id"]}
      true -> :default
    end
  end

  # Arguments are validated as written (a `DynamicBoolean` admits a
  # nested call), then resolved, and the resolved values are handed to
  # the function. From v1.0 a system function (`@index`) belongs to no
  # catalog and skips catalog resolution.
  defp execute(context, name, raw_args, catalog) do
    with :ok <- check_argument_count(name, raw_args),
         {:ok, function} <- find_callee(context, name, raw_args, catalog) do
      {resolved, effects} = resolve(context, raw_args, [])
      run(function, resolved || %{}, context, Enum.reverse(effects), name)
    else
      {:error, %A2UICore.Error{} = error} -> {:error, error_payload(error, name), []}
    end
  end

  defp find_callee(context, "@" <> _ = name, raw_args, catalog) do
    if v1?(context),
      do: system_function(context, name, raw_args, catalog),
      else: catalog_function(context, name, raw_args, catalog)
  end

  defp find_callee(context, name, raw_args, catalog),
    do: catalog_function(context, name, raw_args, catalog)

  defp system_function(_context, name, _raw_args, {:named, _id}) do
    {:error,
     A2UICore.Error.new(
       :expression,
       "EXPRESSION_ERROR",
       "System function '#{name}' belongs to no catalog and must not name a catalogId"
     )}
  end

  defp system_function(context, name, raw_args, :default) do
    version = context.protocol_version

    with {:ok, _args} <- Payload.validate_system_function(name, raw_args, version) do
      case Enum.find(System.functions(version), &(&1.name == name)) do
        nil ->
          {:error,
           A2UICore.Error.new(
             :expression,
             "EXPRESSION_ERROR",
             "System function '#{name}' not found."
           )}

        function ->
          {:ok, function}
      end
    end
  end

  defp catalog_function(context, name, raw_args, catalog) do
    with {:ok, catalog} <- target_catalog(context, name, catalog),
         {:ok, _validated} <- Payload.validate_function(catalog, name, raw_args) do
      find_function(catalog, name)
    end
  end

  defp run(%{execute: nil}, _args, _context, effects, _name), do: {:ok, nil, effects}

  defp run(%{execute: execute}, args, context, effects, name) do
    case execute.(args, context) do
      {:ok, value} -> {:ok, value, effects}
      {:ok, value, found} -> {:ok, value, effects ++ found}
      {:error, error} -> {:error, error_payload(error, name), effects}
    end
  end

  defp check_argument_count(name, raw_args) when is_map(raw_args) do
    if map_size(raw_args) > @max_function_args do
      {:error,
       A2UICore.Error.new(
         :expression,
         "EXPRESSION_ERROR",
         "Function call '#{name}' exceeds maximum allowed arguments count " <>
           "(#{@max_function_args})"
       )}
    else
      :ok
    end
  end

  defp check_argument_count(_name, _raw_args), do: :ok

  # A call runs in the catalog it names, looked up among the catalogs the
  # scope reaches, or else in the default catalog; there is no other
  # fallback.
  defp target_catalog(context, _name, {:named, catalog_id}) do
    case Map.fetch(context.catalogs, catalog_id) do
      {:ok, catalog} ->
        {:ok, catalog}

      :error ->
        {:error,
         A2UICore.Error.new(:catalog, "CATALOG_ERROR", "Catalog not found: #{catalog_id}")}
    end
  end

  defp target_catalog(%__MODULE__{catalog: nil, surface_id: nil}, name, :default) do
    {:error,
     A2UICore.Error.new(
       :catalog,
       "CATALOG_ERROR",
       "Function call '#{name}' names no catalogId and the context has no default catalog."
     )}
  end

  defp target_catalog(%__MODULE__{catalog: nil} = context, name, :default) do
    {:error,
     A2UICore.Error.new(
       :catalog,
       "CATALOG_ERROR",
       "Function call '#{name}' names no catalogId and surface #{context.surface_id} " <>
         "has no default catalogId."
     )}
  end

  defp target_catalog(context, _name, :default), do: {:ok, context.catalog}

  defp find_function(catalog, name) do
    case Catalog.get_function(catalog, name) do
      nil ->
        {:error,
         A2UICore.Error.new(
           :expression,
           "EXPRESSION_ERROR",
           "Function '#{name}' not found in catalog '#{catalog.catalog_id}'."
         )}

      function ->
        {:ok, function}
    end
  end

  defp missing_binding(path) do
    {:warning,
     %{
       code: "MISSING_DATA_BINDING",
       path: path,
       message:
         "Preflight DataBinding Warning: The bound JSON Pointer '#{path}' does not " <>
           "physically exist in the active DataModel. Evaluating to None."
     }}
  end

  # A call whose catalog cannot be resolved is a catalog fault, not a
  # broken expression: the function may exist in a catalog the surface
  # does not have.
  defp error_payload(%A2UICore.Error{} = error, expression) do
    code = if error.category == :catalog, do: "CATALOG_ERROR", else: "EXPRESSION_ERROR"
    payload = %{code: code, message: error.message, expression: expression}
    if error.details == [], do: payload, else: Map.put(payload, :details, error.details)
  end

  defp dedupe_warnings(effects) do
    {kept, _seen} =
      Enum.reduce(effects, {[], MapSet.new()}, fn
        {:warning, %{path: path}} = effect, {kept, seen} ->
          if MapSet.member?(seen, path),
            do: {kept, seen},
            else: {[effect | kept], MapSet.put(seen, path)}

        effect, {kept, seen} ->
          {[effect | kept], seen}
      end)

    Enum.reverse(kept)
  end

  defp with_trailing_slash(path) do
    if String.ends_with?(path, "/"), do: path, else: path <> "/"
  end
end

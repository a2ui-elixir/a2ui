defmodule A2UICore.Schema.Ref do
  @moduledoc false

  # `$ref` and `$dynamicRef` resolution.
  #
  # A reference is resolved against the base URI of the schema it sits in
  # (set by the nearest `$id`, RFC 3986). The document it names is found,
  # in order:
  #
  #   * the current resource, for a fragment-only reference;
  #   * the registry entry keyed by the resolved URI, then by the
  #     reference as written (the A2UI schemas name documents like
  #     "common_types.json" and bind "catalog.json" to the active catalog);
  #   * the registry document whose `$id` is the resolved URI;
  #   * a subschema with that `$id` inside the current document or a
  #     registry document (an embedded resource);
  #   * the registry entry whose URL ends in the same file name.
  #
  # The fragment is then a JSON pointer (percent-decoded) or a plain name
  # matched against `$anchor` and `$dynamicAnchor` in the resource.
  #
  # The resolved location is `%{schema, root, base, doc}`: the target, the
  # resource it belongs to (local fragments resolve against it), the base
  # URI in effect at that resource (its own `$id` applied) and the
  # document that holds it.

  alias A2UICore.Error
  alias A2UICore.Pointer

  @max_ref_depth 64

  # Keywords whose values are data, not schemas: an `$id` inside them
  # names nothing.
  @data_keywords ~w(const enum examples default)

  @type registry :: %{optional(String.t()) => A2UICore.Schema.schema()}

  @type location :: %{
          schema: A2UICore.Schema.schema(),
          root: A2UICore.Schema.schema(),
          base: String.t() | nil,
          doc: A2UICore.Schema.schema()
        }

  @doc """
  Resolves `ref` from `ctx` (its `root`, `base`, `doc`, `registry` and
  `ref_depth`). Returns `{:ok, location}` or `{:error, error}` when the
  target is missing or the recursion limit is hit.
  """
  @spec resolve(String.t(), map()) :: {:ok, location()} | {:error, Error.t()}
  def resolve(ref, %{ref_depth: depth}) when depth >= @max_ref_depth,
    do: {:error, invalid("$ref recursion limit (#{@max_ref_depth}) exceeded at '#{ref}'")}

  def resolve(ref, ctx) when is_binary(ref) do
    {target, fragment} = split(ref)

    with {:ok, resource} <- resource(target, ctx) do
      locate(resource, URI.decode(fragment), ref)
    end
  end

  @doc """
  Resolves `$dynamicRef`: as `$ref`, except that when its fragment names
  a `$dynamicAnchor` that the initial target declares, the outermost
  resource of the dynamic `scope` (outermost first) declaring the same
  dynamic anchor is used instead.
  """
  @spec resolve_dynamic(String.t(), map(), [location()]) ::
          {:ok, location()} | {:error, Error.t()}
  def resolve_dynamic(ref, ctx, scope) do
    with {:ok, initial} <- resolve(ref, ctx) do
      {_target, fragment} = split(ref)
      name = URI.decode(fragment)

      if anchor_name?(name) and dynamic_anchor(initial.schema) == name do
        {:ok, Enum.find_value(scope, initial, &find_anchor(&1, name, :dynamic))}
      else
        {:ok, initial}
      end
    end
  end

  @doc """
  The base URI `id` sets under `base`: `id` resolved against it, without
  a fragment.
  """
  @spec rebase(String.t() | nil, String.t()) :: String.t()
  def rebase(base, id), do: base |> join(id) |> strip_fragment()

  # -- documents and resources ---------------------------------------------------

  defp split(ref) do
    case String.split(ref, "#", parts: 2) do
      [target] -> {target, ""}
      [target, fragment] -> {target, fragment}
    end
  end

  defp resource("", ctx), do: {:ok, %{root: ctx.root, base: ctx.base, doc: ctx.doc}}

  defp resource(target, ctx) do
    uri = ctx.base |> join(target) |> strip_fragment()

    lookup_key(ctx.registry, uri) ||
      lookup_key(ctx.registry, target) ||
      lookup_id(ctx.registry, uri) ||
      embedded([{ctx.doc, nil} | Enum.map(ctx.registry, fn {key, doc} -> {doc, key} end)], uri) ||
      lookup_basename(ctx.registry, target) ||
      {:error, invalid("Cannot resolve $ref '#{target}': no such document in registry")}
  end

  defp lookup_key(registry, key) do
    case Map.fetch(registry, key) do
      {:ok, doc} -> {:ok, %{root: doc, base: document_base(doc, key), doc: doc}}
      :error -> nil
    end
  end

  defp lookup_id(registry, uri) do
    Enum.find_value(registry, fn {key, doc} ->
      if document_base(doc, key) == uri, do: {:ok, %{root: doc, base: uri, doc: doc}}
    end)
  end

  defp lookup_basename(registry, target) do
    name = base_name(target)

    Enum.find_value(registry, fn {key, doc} ->
      if base_name(key) == name, do: {:ok, %{root: doc, base: document_base(doc, key), doc: doc}}
    end)
  end

  @doc """
  The base URI of a document registered under `key` (`nil` for none):
  its own `$id` resolved against the key.
  """
  @spec document_base(A2UICore.Schema.schema(), String.t() | nil) :: String.t() | nil
  def document_base(%{"$id" => id}, key) when is_binary(id), do: rebase(absolute_or_nil(key), id)
  def document_base(_doc, key), do: absolute_or_nil(key)

  defp absolute_or_nil(key), do: if(absolute?(key), do: strip_fragment(key))

  defp embedded(docs, uri),
    do: Enum.find_value(docs, fn {doc, key} -> embedded_in(doc, absolute_or_nil(key), uri) end)

  defp embedded_in(doc, base, uri) do
    case List.keyfind(resources(doc, base), uri, 0) do
      {base, schema} -> {:ok, %{root: schema, base: base, doc: doc}}
      nil -> nil
    end
  end

  # Every subschema of `doc` that has an `$id`, with the base URI it sets.
  defp resources(doc, base), do: collect_resources(doc, base, [])

  defp collect_resources(%{} = schema, base, acc) do
    {base, acc} =
      case schema do
        %{"$id" => id} when is_binary(id) ->
          base = rebase(base, id)
          {base, [{base, schema} | acc]}

        _no_id ->
          {base, acc}
      end

    Enum.reduce(schema, acc, fn
      {key, _value}, acc when key in @data_keywords -> acc
      {_key, value}, acc -> collect_resources(value, base, acc)
    end)
  end

  defp collect_resources(list, base, acc) when is_list(list),
    do: Enum.reduce(list, acc, &collect_resources(&1, base, &2))

  defp collect_resources(_value, _base, acc), do: acc

  # -- fragments -------------------------------------------------------------------

  defp locate(resource, "", _ref), do: {:ok, Map.put(resource, :schema, resource.root)}

  defp locate(resource, "/" <> _ = pointer, ref) do
    tokens =
      pointer
      |> String.trim_leading("/")
      |> String.split("/")
      |> Enum.map(&Pointer.unescape_segment/1)

    case walk(resource.root, tokens, resource.root, resource.base) do
      {:ok, schema, root, base} ->
        {:ok, %{resource | root: root, base: base} |> Map.put(:schema, schema)}

      :error ->
        {:error, invalid("Cannot resolve $ref '#{ref}': JSON pointer '#{pointer}' not found")}
    end
  end

  defp locate(resource, name, ref) do
    case find_anchor(resource, name, :any) do
      nil -> {:error, invalid("Cannot resolve $ref '#{ref}': no anchor '#{name}'")}
      location -> {:ok, location}
    end
  end

  # Follows pointer tokens. Every subschema with an `$id` on the way down
  # starts a resource: the target's resource is the innermost one, with
  # the base URI in effect there.
  defp walk(value, [], root, base), do: {:ok, value, root, base}

  defp walk(value, [token | rest], root, base) do
    case child(value, token) do
      {:ok, %{"$id" => id} = inner} when is_binary(id) ->
        walk(inner, rest, inner, rebase(base, id))

      {:ok, inner} ->
        walk(inner, rest, root, base)

      :error ->
        :error
    end
  end

  defp child(%{} = value, token), do: Map.fetch(value, token)

  defp child(list, token) when is_list(list) do
    with true <- Pointer.array_index?(token),
         index = String.to_integer(token),
         true <- index < length(list) do
      {:ok, Enum.at(list, index)}
    else
      _ -> :error
    end
  end

  defp child(_value, _token), do: :error

  # The subschema of `resource` declaring the anchor `name` (`:any` for
  # `$anchor` or `$dynamicAnchor`, `:dynamic` for `$dynamicAnchor` only),
  # without entering embedded resources.
  defp find_anchor(%{root: root} = resource, name, kind) do
    case anchored(root, name, kind, true) do
      nil -> nil
      schema -> Map.put(resource, :schema, schema)
    end
  end

  defp anchored(%{} = schema, name, kind, top?) do
    cond do
      not top? and is_binary(schema["$id"]) -> nil
      declares?(schema, name, kind) -> schema
      true -> Enum.find_value(schema, &anchored_in(&1, name, kind))
    end
  end

  defp anchored(list, name, kind, _top?) when is_list(list),
    do: Enum.find_value(list, &anchored(&1, name, kind, false))

  defp anchored(_value, _name, _kind, _top?), do: nil

  defp anchored_in({key, _value}, _name, _kind) when key in @data_keywords, do: nil
  defp anchored_in({_key, value}, name, kind), do: anchored(value, name, kind, false)

  defp declares?(schema, name, :dynamic), do: schema["$dynamicAnchor"] == name

  defp declares?(schema, name, :any),
    do: schema["$anchor"] == name or schema["$dynamicAnchor"] == name

  defp dynamic_anchor(%{"$dynamicAnchor" => name}), do: name
  defp dynamic_anchor(_schema), do: nil

  defp anchor_name?(name), do: name != "" and not String.starts_with?(name, "/")

  # -- URIs ------------------------------------------------------------------------

  defp join(nil, ref), do: ref
  defp join(base, ref), do: if(absolute?(ref), do: ref, else: merge(base, ref))

  defp merge(base, ref) do
    base |> URI.merge(ref) |> URI.to_string()
  rescue
    ArgumentError -> ref
  end

  defp absolute?(uri), do: is_binary(uri) and URI.parse(uri).scheme not in [nil, ""]

  defp strip_fragment(uri), do: uri |> String.split("#", parts: 2) |> hd()

  defp base_name(name) do
    name
    |> strip_fragment()
    |> String.trim_leading("https://")
    |> String.trim_leading("http://")
    |> String.split("/")
    |> List.last()
  end

  defp invalid(message), do: Error.new(:validation, "invalid_reference", message)
end

defmodule A2UICore.Schema.Engine do
  @moduledoc false

  # Draft 2020-12 keyword evaluator backing A2UICore.Schema.
  #
  # eval/3 returns `{annotations, errors}`.
  #
  # Annotations (`%{props: MapSet, items: MapSet}`) record which object
  # keys / array indices were evaluated *at this instance level* so a
  # schema-level `unevaluatedProperties` (the A2UI v1.0 Component envelope
  # relies on this via allOf(ComponentCommon, anyComponent, …)) can reject
  # properties that no branch consumed. Annotation scoping rules:
  #
  #   * `properties`/`patternProperties`/`additionalProperties` annotate
  #     the keys they matched/validated against THIS instance.
  #   * `$ref`/`allOf`/`anyOf`/`oneOf`/`if`→`then`/`else` evaluate
  #     subschemas against THIS instance, so their annotations merge in —
  #     but only from branches that validated without errors (per 2020-12,
  #     annotations of failed branches are dropped).
  #   * `not` never contributes annotations.
  #   * Descending into a property VALUE or array ELEMENT evaluates a
  #     DIFFERENT instance; the child's annotations are discarded at this
  #     level (the child handles its own unevaluated* keywords internally).
  #
  # Detail codes mirror the reference mapping:
  #
  #   required, minProperties            -> "missing_field"
  #   additionalProperties,
  #   unevaluatedProperties              -> "extra_field"
  #   type, pattern, enum, format        -> "type_mismatch"
  #   everything else                    -> "invalid_value"
  #   unresolvable $ref                  -> "invalid_reference"

  alias A2UICore.Error.Detail
  alias A2UICore.Schema.{ECMA262, Ref}

  @typedoc "Evaluation annotations."
  @type annotations :: %{props: MapSet.t(String.t()), items: MapSet.t(non_neg_integer())}

  @typedoc "Evaluation context."
  @type ctx :: %{
          registry: Ref.registry(),
          root: A2UICore.Schema.schema(),
          path: [String.t() | non_neg_integer()],
          ref_depth: non_neg_integer()
        }

  @empty_ann %{props: MapSet.new(), items: MapSet.new()}

  # ----------------------------------------------------------------- entry --

  @doc false
  @spec eval(term(), A2UICore.Schema.schema(), ctx()) :: {annotations(), [Detail.t()]}

  def eval(_data, true, _ctx), do: {@empty_ann, []}

  def eval(_data, schema, _ctx) when is_map(schema) and map_size(schema) == 0,
    do: {@empty_ann, []}

  def eval(_data, false, ctx),
    do: {@empty_ann, [detail(ctx, "invalid_value", "False schema does not allow any value")]}

  def eval(_data, schema, _ctx) when not is_map(schema),
    do: raise(ArgumentError, "Invalid schema: #{inspect(schema)}")

  def eval(data, %{"$ref" => ref} = schema, ctx) when is_binary(ref) do
    case Ref.resolve(ref, ctx.root, ctx.registry, ctx.ref_depth) do
      {:ok, resolved_root, subschema} ->
        ref_ctx = %{ctx | root: resolved_root, ref_depth: ctx.ref_depth + 1}
        target = eval(data, subschema, ref_ctx)
        siblings = Map.delete(schema, "$ref")

        if map_size(siblings) == 0 do
          target
        else
          # 2020-12: `$ref` no longer short-circuits; siblings apply too,
          # against the ORIGINAL context (only the ref target switches root).
          combine(target, eval(data, siblings, ctx))
        end

      {:error, err} ->
        {@empty_ann, [Detail.new("invalid_reference", err.message, path_str(ctx))]}
    end
  end

  def eval(data, schema, ctx) when is_map(schema) do
    {ann_a, errs_a} = eval_assertions(data, schema, ctx)
    {ann_b, errs_b} = eval_applicators(data, schema, ctx)
    {ann_c, errs_c} = eval_if_then_else(data, schema, ctx)

    ann = merge_annots(merge_annots(ann_a, ann_b), ann_c)

    # `unevaluatedProperties` must see everything the other keywords and
    # applicators consumed, so it runs last with the merged annotations.
    {ann_d, errs_d} = eval_unevaluated(data, schema, ctx, ann)

    {merge_annots(ann, ann_d), errs_a ++ errs_b ++ errs_c ++ errs_d}
  end

  # -------------------------------------------------------------- plumbing --

  @spec combine({annotations(), [Detail.t()]}, {annotations(), [Detail.t()]}) ::
          {annotations(), [Detail.t()]}
  defp combine({a, ea}, {b, eb}), do: {merge_annots(a, b), ea ++ eb}

  @spec merge_annots(annotations(), annotations()) :: annotations()
  defp merge_annots(a, b),
    do: %{props: MapSet.union(a.props, b.props), items: MapSet.union(a.items, b.items)}

  @spec props([String.t()]) :: annotations()
  defp props(keys), do: %{@empty_ann | props: MapSet.new(keys)}

  @spec detail(ctx(), String.t(), String.t()) :: Detail.t()
  defp detail(%{path: path}, code, message), do: Detail.new(code, message, join(path))

  @spec detail(ctx(), String.t(), String.t(), String.t() | non_neg_integer()) :: Detail.t()
  defp detail(%{path: path}, code, message, field),
    do: Detail.new(code, message, join(path ++ [field]))

  @spec join([String.t() | non_neg_integer()]) :: String.t()
  defp join(path), do: Enum.map_join(path, ".", &to_string/1)

  @spec path_str(ctx()) :: String.t()
  defp path_str(%{path: path}), do: join(path)

  @spec sub_ctx(ctx(), String.t() | non_neg_integer()) :: ctx()
  defp sub_ctx(ctx, seg), do: %{ctx | path: ctx.path ++ [seg]}

  @spec repr(term()) :: String.t()
  defp repr(value) when is_binary(value), do: "'#{value}'"
  defp repr(nil), do: "null"
  defp repr(value) when is_boolean(value), do: to_string(value)
  defp repr(value), do: inspect(value)

  defguardp plain_map?(value) when is_map(value) and not is_map_key(value, :__struct__)

  # --------------------------------------------------------------- assertions --

  @spec eval_assertions(term(), map(), ctx()) :: {annotations(), [Detail.t()]}
  defp eval_assertions(data, schema, ctx) do
    eval_type(data, schema, ctx)
    |> combine(eval_const(data, schema, ctx))
    |> combine(eval_enum(data, schema, ctx))
    |> combine(eval_string(data, schema, ctx))
    |> combine(eval_numeric(data, schema, ctx))
    |> combine(eval_array(data, schema, ctx))
    |> combine(eval_object(data, schema, ctx))
  end

  # -- type --------------------------------------------------------------

  @spec eval_type(term(), map(), ctx()) :: {annotations(), [Detail.t()]}
  defp eval_type(data, %{"type" => type}, ctx) do
    if type_match?(data, type) do
      {@empty_ann, []}
    else
      {@empty_ann,
       [detail(ctx, "type_mismatch", "#{repr(data)} is not of type #{type_repr(type)}")]}
    end
  end

  defp eval_type(_data, _schema, _ctx), do: {@empty_ann, []}

  @doc false
  @spec type_match?(term(), String.t() | [String.t()]) :: boolean()
  def type_match?(data, types) when is_list(types),
    do: Enum.any?(types, &type_match?(data, &1))

  def type_match?(data, "string"), do: is_binary(data)
  def type_match?(data, "boolean"), do: is_boolean(data)
  def type_match?(data, "object"), do: plain_map?(data)
  def type_match?(data, "array"), do: is_list(data)
  def type_match?(data, "null"), do: is_nil(data)
  def type_match?(data, "number"), do: is_number(data)
  def type_match?(data, "integer"), do: is_number(data) and data == trunc(data)
  def type_match?(_data, _other), do: false

  @spec type_repr(String.t() | [String.t()]) :: String.t()
  defp type_repr(type) when is_binary(type), do: "'#{type}'"

  defp type_repr(types) when is_list(types),
    do: Enum.map_join(types, ", ", &"'#{&1}'")

  # -- const / enum ------------------------------------------------------

  @spec eval_const(term(), map(), ctx()) :: {annotations(), [Detail.t()]}
  defp eval_const(data, %{"const" => expected}, ctx) do
    if json_equal?(data, expected) do
      {@empty_ann, []}
    else
      {@empty_ann, [detail(ctx, "invalid_value", "#{repr(expected)} was expected")]}
    end
  end

  defp eval_const(_data, _schema, _ctx), do: {@empty_ann, []}

  @spec eval_enum(term(), map(), ctx()) :: {annotations(), [Detail.t()]}
  defp eval_enum(data, %{"enum" => values}, ctx) do
    if Enum.any?(values, &json_equal?(data, &1)) do
      {@empty_ann, []}
    else
      {@empty_ann,
       [detail(ctx, "type_mismatch", "#{repr(data)} is not one of #{inspect(values)}")]}
    end
  end

  defp eval_enum(_data, _schema, _ctx), do: {@empty_ann, []}

  @doc false
  @spec json_equal?(term(), term()) :: boolean()
  def json_equal?(a, b) when is_number(a) and is_number(b), do: a == b

  def json_equal?(a, b) when is_list(a) and is_list(b),
    do: length(a) == length(b) and Enum.all?(Enum.zip(a, b), fn {x, y} -> json_equal?(x, y) end)

  def json_equal?(a, b) when plain_map?(a) and plain_map?(b) do
    map_size(a) == map_size(b) and
      Enum.all?(a, fn {k, v} -> Map.has_key?(b, k) and json_equal?(v, Map.get(b, k)) end)
  end

  def json_equal?(a, b), do: a === b

  # -- strings -----------------------------------------------------------

  @spec eval_string(term(), map(), ctx()) :: {annotations(), [Detail.t()]}
  defp eval_string(data, schema, ctx) when is_binary(data) do
    eval_string_length(data, schema, ctx, "minLength")
    |> combine(eval_string_length(data, schema, ctx, "maxLength"))
    |> combine(eval_pattern(data, schema, ctx))
  end

  defp eval_string(_data, _schema, _ctx), do: {@empty_ann, []}

  @spec eval_string_length(String.t(), map(), ctx(), String.t()) ::
          {annotations(), [Detail.t()]}
  defp eval_string_length(data, schema, ctx, key) do
    case Map.fetch(schema, key) do
      :error ->
        {@empty_ann, []}

      {:ok, bound} when is_integer(bound) ->
        string_length_result(data, ctx, key, bound)
    end
  end

  @spec string_length_result(String.t(), ctx(), String.t(), integer()) ::
          {annotations(), [Detail.t()]}
  defp string_length_result(data, ctx, key, bound) do
    # JSON Schema counts Unicode codepoints (like Python's len()).
    len = length(String.codepoints(data))

    if (key == "minLength" and len >= bound) or (key == "maxLength" and len <= bound) do
      {@empty_ann, []}
    else
      verb = if key == "minLength", do: "too short", else: "too long"
      {@empty_ann, [detail(ctx, "invalid_value", "#{repr(data)} is #{verb} (#{bound})")]}
    end
  end

  @spec eval_pattern(term(), map(), ctx()) :: {annotations(), [Detail.t()]}
  defp eval_pattern(data, %{"pattern" => pattern}, ctx) when is_binary(data) do
    case ECMA262.search(pattern, data) do
      {:ok, true} ->
        {@empty_ann, []}

      {:ok, false} ->
        {@empty_ann,
         [detail(ctx, "type_mismatch", "#{repr(data)} does not match #{repr(pattern)}")]}

      {:error, err} ->
        {@empty_ann, [detail(ctx, "invalid_value", err.message)]}
    end
  end

  defp eval_pattern(_data, _schema, _ctx), do: {@empty_ann, []}

  # -- numbers -----------------------------------------------------------

  @spec eval_numeric(term(), map(), ctx()) :: {annotations(), [Detail.t()]}
  defp eval_numeric(data, schema, ctx) when is_number(data) do
    schema
    |> Map.take(["minimum", "maximum", "exclusiveMinimum", "exclusiveMaximum", "multipleOf"])
    |> Enum.reduce({@empty_ann, []}, fn {key, bound}, {ann, errs} ->
      if numeric_ok?(data, key, bound) do
        {ann, errs}
      else
        {ann, errs ++ [detail(ctx, "invalid_value", numeric_message(data, key, bound))]}
      end
    end)
  end

  defp eval_numeric(_data, _schema, _ctx), do: {@empty_ann, []}

  @spec numeric_ok?(number(), String.t(), number()) :: boolean()
  defp numeric_ok?(data, "minimum", bound), do: data >= bound
  defp numeric_ok?(data, "maximum", bound), do: data <= bound
  defp numeric_ok?(data, "exclusiveMinimum", bound), do: data > bound
  defp numeric_ok?(data, "exclusiveMaximum", bound), do: data < bound

  defp numeric_ok?(data, "multipleOf", bound) when bound != 0 do
    quotient = data / bound
    abs(quotient - round(quotient)) < 1.0e-9
  end

  defp numeric_ok?(_data, _key, _bound), do: false

  @spec numeric_message(number(), String.t(), number()) :: String.t()
  defp numeric_message(data, "minimum", bound),
    do: "#{repr(data)} is less than the minimum of #{repr(bound)}"

  defp numeric_message(data, "maximum", bound),
    do: "#{repr(data)} is greater than the maximum of #{repr(bound)}"

  defp numeric_message(data, "exclusiveMinimum", bound),
    do: "#{repr(data)} is less than or equal to the exclusive minimum of #{repr(bound)}"

  defp numeric_message(data, "exclusiveMaximum", bound),
    do: "#{repr(data)} is greater than or equal to the exclusive maximum of #{repr(bound)}"

  defp numeric_message(data, "multipleOf", bound),
    do: "#{repr(data)} is not a multiple of #{repr(bound)}"

  # -- arrays ------------------------------------------------------------

  @spec eval_array(term(), map(), ctx()) :: {annotations(), [Detail.t()]}
  defp eval_array(data, schema, ctx) when is_list(data) do
    eval_array_size(data, schema, ctx)
    |> combine(eval_unique_items(data, ctx, schema))
    |> combine(eval_contains(data, schema, ctx))
    |> combine(eval_prefix_items(data, schema, ctx))
    |> combine(eval_items(data, schema, ctx))
  end

  defp eval_array(_data, _schema, _ctx), do: {@empty_ann, []}

  @spec eval_array_size([term()], map(), ctx()) :: {annotations(), [Detail.t()]}
  defp eval_array_size(data, schema, ctx) do
    errs =
      case Map.fetch(schema, "minItems") do
        {:ok, bound} when is_integer(bound) and length(data) < bound ->
          [detail(ctx, "invalid_value", "#{repr(data)} is too short (minimum #{bound})")]

        _ ->
          []
      end ++
        case Map.fetch(schema, "maxItems") do
          {:ok, bound} when is_integer(bound) and length(data) > bound ->
            [detail(ctx, "invalid_value", "#{repr(data)} is too long (maximum #{bound})")]

          _ ->
            []
        end

    {@empty_ann, errs}
  end

  @spec eval_unique_items([term()], ctx(), map()) :: {annotations(), [Detail.t()]}
  defp eval_unique_items(data, ctx, %{"uniqueItems" => true}) do
    if unique?(data) do
      {@empty_ann, []}
    else
      {@empty_ann, [detail(ctx, "invalid_value", "#{repr(data)} has non-unique elements")]}
    end
  end

  defp eval_unique_items(_data, _ctx, _schema), do: {@empty_ann, []}

  @spec unique?([term()]) :: boolean()
  defp unique?(list) do
    list
    |> Enum.reduce([], fn item, seen ->
      if Enum.any?(seen, &json_equal?(&1, item)), do: throw(:dup)
      [item | seen]
    end)
    |> then(fn _ -> true end)
  catch
    :dup -> false
  end

  @spec eval_contains([term()], map(), ctx()) :: {annotations(), [Detail.t()]}
  defp eval_contains(data, %{"contains" => subschema}, ctx) do
    if Enum.any?(data, &matches_subschema(&1, subschema, ctx)) do
      {@empty_ann, []}
    else
      {@empty_ann,
       [
         detail(
           ctx,
           "invalid_value",
           "#{repr(data)} does not contain any element matching the given schema"
         )
       ]}
    end
  end

  defp eval_contains(_data, _schema, _ctx), do: {@empty_ann, []}

  @spec matches_subschema(term(), term(), ctx()) :: boolean()
  defp matches_subschema(item, subschema, ctx) do
    case eval(item, subschema, ctx) do
      {_, []} -> true
      _ -> false
    end
  end

  @spec eval_prefix_items([term()], map(), ctx()) :: {annotations(), [Detail.t()]}
  defp eval_prefix_items(data, %{"prefixItems" => prefix}, ctx) do
    prefix
    |> Enum.with_index()
    |> Enum.reduce({props([]), []}, fn {subschema, idx}, {ann, errs} ->
      if idx < length(data) do
        # Child annotations apply to the ELEMENT instance, not this array.
        {_, child_errs} = eval(Enum.at(data, idx), subschema, sub_ctx(ctx, idx))
        {%{ann | items: MapSet.put(ann.items, idx)}, errs ++ child_errs}
      else
        {ann, errs}
      end
    end)
  end

  defp eval_prefix_items(_data, _schema, _ctx), do: {@empty_ann, []}

  @spec eval_items([term()], map(), ctx()) :: {annotations(), [Detail.t()]}
  defp eval_items(data, schema, ctx) do
    prefix_count = prefix_count(schema)

    case Map.fetch(schema, "items") do
      :error when prefix_count == 0 ->
        {@empty_ann, []}

      :error ->
        {@empty_ann, []}

      {:ok, false} ->
        if length(data) > prefix_count do
          {@empty_ann,
           [
             detail(
               ctx,
               "invalid_value",
               "#{repr(data)} is too long (prefixItems is the whole tuple)"
             )
           ]}
        else
          {@empty_ann, []}
        end

      {:ok, subschema} when is_map(subschema) or is_boolean(subschema) ->
        data
        |> Enum.drop(prefix_count)
        |> Enum.with_index()
        |> Enum.reduce({@empty_ann, []}, fn {item, offset}, {ann, errs} ->
          idx = offset + prefix_count

          # Child annotations apply to the ELEMENT instance, not this array.
          {_, child_errs} = eval(item, subschema, sub_ctx(ctx, idx))

          # `items` marks the index evaluated at this level regardless of
          # whether the element validated (errors fail the schema anyway).
          {%{@empty_ann | items: MapSet.union(ann.items, MapSet.new([idx]))}, errs ++ child_errs}
        end)
    end
  end

  @spec prefix_count(map()) :: non_neg_integer()
  defp prefix_count(%{"prefixItems" => prefix}) when is_list(prefix), do: length(prefix)
  defp prefix_count(_schema), do: 0

  # -- objects -----------------------------------------------------------

  @spec eval_object(term(), map(), ctx()) :: {annotations(), [Detail.t()]}
  defp eval_object(data, schema, ctx) when is_map(data) do
    eval_object_size(data, schema, ctx)
    |> combine(eval_required(data, schema, ctx))
    |> combine(eval_properties(data, schema, ctx))
    |> combine(eval_pattern_properties(data, schema, ctx))
    |> combine(eval_property_names(data, schema, ctx))
    |> combine(eval_additional_properties(data, schema, ctx))
  end

  defp eval_object(_data, _schema, _ctx), do: {@empty_ann, []}

  @spec eval_object_size(map(), map(), ctx()) :: {annotations(), [Detail.t()]}
  defp eval_object_size(data, schema, ctx) do
    errs =
      case Map.fetch(schema, "minProperties") do
        {:ok, bound} when map_size(data) < bound ->
          [detail(ctx, "missing_field", "#{repr(data)} has too few properties (#{bound})")]

        _ ->
          []
      end ++
        case Map.fetch(schema, "maxProperties") do
          {:ok, bound} when map_size(data) > bound ->
            [detail(ctx, "extra_field", "#{repr(data)} has too many properties (#{bound})")]

          _ ->
            []
        end

    {@empty_ann, errs}
  end

  @spec eval_required(map(), map(), ctx()) :: {annotations(), [Detail.t()]}
  defp eval_required(data, %{"required" => names}, ctx) when is_list(names) do
    errs =
      for name <- names, not Map.has_key?(data, name) do
        detail(ctx, "missing_field", "'#{name}' is a required property", name)
      end

    {@empty_ann, errs}
  end

  defp eval_required(_data, _schema, _ctx), do: {@empty_ann, []}

  @spec eval_properties(map(), map(), ctx()) :: {annotations(), [Detail.t()]}
  defp eval_properties(data, %{"properties" => declared}, ctx) when is_map(declared) do
    Enum.reduce(declared, {props([]), []}, fn {name, subschema}, {ann, errs} ->
      if Map.has_key?(data, name) do
        # Child annotations apply to the VALUE instance, not this object.
        {_, child_errs} = eval(Map.get(data, name), subschema, sub_ctx(ctx, name))
        {%{ann | props: MapSet.put(ann.props, name)}, errs ++ child_errs}
      else
        {ann, errs}
      end
    end)
  end

  defp eval_properties(_data, _schema, _ctx), do: {@empty_ann, []}

  @spec eval_pattern_properties(map(), map(), ctx()) :: {annotations(), [Detail.t()]}
  defp eval_pattern_properties(data, %{"patternProperties" => patterns}, ctx)
       when is_map(patterns) do
    Enum.reduce(patterns, {props([]), []}, fn {pattern, subschema}, acc ->
      apply_pattern_properties(data, pattern, subschema, ctx, acc)
    end)
  end

  defp eval_pattern_properties(_data, _schema, _ctx), do: {@empty_ann, []}

  @spec apply_pattern_properties(map(), String.t(), term(), ctx(), {annotations(), [Detail.t()]}) ::
          {annotations(), [Detail.t()]}
  defp apply_pattern_properties(data, pattern, subschema, ctx, {ann, errs}) do
    case matched_keys(data, pattern) do
      {:ok, keys} ->
        Enum.reduce(keys, {ann, errs}, fn key, {ann_acc, errs_acc} ->
          {_, child_errs} = eval(Map.get(data, key), subschema, sub_ctx(ctx, key))
          {%{ann_acc | props: MapSet.put(ann_acc.props, key)}, errs_acc ++ child_errs}
        end)

      {:error, err} ->
        {ann, errs ++ [detail(ctx, "invalid_value", err.message)]}
    end
  end

  @spec matched_keys(map(), String.t()) :: {:ok, [String.t()]} | {:error, A2UICore.Error.t()}
  defp matched_keys(data, pattern) do
    case ECMA262.compile(pattern) do
      {:ok, regex} -> {:ok, Enum.filter(Map.keys(data), &Regex.match?(regex, &1))}
      {:error, err} -> {:error, err}
    end
  end

  @spec eval_property_names(map(), map(), ctx()) :: {annotations(), [Detail.t()]}
  defp eval_property_names(data, %{"propertyNames" => subschema}, ctx) do
    Enum.reduce(Map.keys(data), {props([]), []}, fn key, {ann, errs} ->
      {_, child_errs} = eval(key, subschema, sub_ctx(ctx, key))
      {ann, errs ++ child_errs}
    end)
  end

  defp eval_property_names(_data, _schema, _ctx), do: {@empty_ann, []}

  @spec eval_additional_properties(map(), map(), ctx()) :: {annotations(), [Detail.t()]}
  defp eval_additional_properties(data, schema, ctx) do
    case Map.fetch(schema, "additionalProperties") do
      :error ->
        {@empty_ann, []}

      {:ok, directive} ->
        extras = additional_extras(data, schema)
        apply_additional_properties(data, directive, extras, schema, ctx)
    end
  end

  @spec additional_extras(map(), map()) :: [String.t()]
  defp additional_extras(data, schema) do
    declared = Map.get(schema, "properties", %{})
    patterns = Map.get(schema, "patternProperties", %{})

    Enum.filter(Map.keys(data), fn key ->
      not Map.has_key?(declared, key) and not pattern_matched?(patterns, key)
    end)
  end

  @spec pattern_matched?(map(), String.t()) :: boolean()
  defp pattern_matched?(patterns, key) do
    Enum.any?(Map.keys(patterns), fn pattern ->
      case ECMA262.search(pattern, key) do
        {:ok, true} -> true
        _ -> false
      end
    end)
  end

  @spec apply_additional_properties(map(), term(), [String.t()], map(), ctx()) ::
          {annotations(), [Detail.t()]}
  defp apply_additional_properties(_data, true, extras, _schema, _ctx),
    do: {props(extras), []}

  defp apply_additional_properties(_data, false, [], _schema, _ctx), do: {@empty_ann, []}

  defp apply_additional_properties(_data, false, extras, schema, ctx),
    do: {@empty_ann, [detail(ctx, "extra_field", additional_properties_message(extras, schema))]}

  defp apply_additional_properties(data, subschema, extras, _schema, ctx)
       when is_map(subschema) or is_boolean(subschema) do
    Enum.reduce(extras, {props(extras), []}, fn key, {ann, errs} ->
      {_, child_errs} = eval(Map.get(data, key), subschema, sub_ctx(ctx, key))
      {ann, errs ++ child_errs}
    end)
  end

  @spec additional_properties_message([String.t()], map()) :: String.t()
  defp additional_properties_message(extras, schema) do
    sorted = Enum.sort(extras)
    joined = quote_keys(sorted)

    if Map.has_key?(schema, "patternProperties") do
      verb = if length(sorted) == 1, do: "does", else: "do"
      pattern_reprs = schema["patternProperties"] |> Map.keys() |> Enum.sort() |> quote_keys()
      "#{joined} #{verb} not match any of the regexes: #{pattern_reprs}"
    else
      verb = if length(sorted) == 1, do: "was", else: "were"
      "Additional properties are not allowed (#{joined} #{verb} unexpected)"
    end
  end

  @spec quote_keys([String.t()]) :: String.t()
  defp quote_keys(keys), do: Enum.map_join(keys, ", ", &"'#{&1}'")

  # -------------------------------------------------------------- applicators --

  @spec eval_applicators(term(), map(), ctx()) :: {annotations(), [Detail.t()]}
  defp eval_applicators(data, schema, ctx) do
    eval_all_of(data, schema, ctx)
    |> combine(eval_any_of(data, schema, ctx))
    |> combine(eval_one_of(data, schema, ctx))
    |> combine(eval_not(data, schema, ctx))
  end

  @spec eval_all_of(term(), map(), ctx()) :: {annotations(), [Detail.t()]}
  defp eval_all_of(data, %{"allOf" => subschemas}, ctx) when is_list(subschemas) do
    Enum.reduce(subschemas, {@empty_ann, []}, fn subschema, {ann, errs} ->
      {sub_ann, sub_errs} = eval(data, subschema, ctx)

      # A failing allOf branch fails the whole schema anyway; keep its
      # annotations only when it validated cleanly (2020-12 annotation rule).
      {merge_or_drop(ann, sub_ann, sub_errs), errs ++ sub_errs}
    end)
  end

  defp eval_all_of(_data, _schema, _ctx), do: {@empty_ann, []}

  @spec eval_any_of(term(), map(), ctx()) :: {annotations(), [Detail.t()]}
  defp eval_any_of(data, %{"anyOf" => subschemas}, ctx) when is_list(subschemas) do
    results = Enum.map(subschemas, &eval(data, &1, ctx))
    {hits, misses} = Enum.split_with(results, fn {_a, errs} -> errs == [] end)

    case hits do
      [] ->
        miss_errs = misses |> Enum.flat_map(&elem(&1, 1)) |> Enum.uniq()
        first = List.first(miss_errs)
        errs = [detail(ctx, "invalid_value", any_of_message(data)) | (first && [first]) || []]
        {@empty_ann, errs}

      hits ->
        ann = Enum.reduce(hits, @empty_ann, fn {a, _}, acc -> merge_annots(acc, a) end)
        {ann, []}
    end
  end

  defp eval_any_of(_data, _schema, _ctx), do: {@empty_ann, []}

  @spec eval_one_of(term(), map(), ctx()) :: {annotations(), [Detail.t()]}
  defp eval_one_of(data, %{"oneOf" => subschemas} = schema, ctx) when is_list(subschemas) do
    results = Enum.map(subschemas, &eval(data, &1, ctx))
    hits = Enum.filter(results, fn {_a, errs} -> errs == [] end)

    case hits do
      [only] ->
        {a, _} = only
        {a, []}

      [] ->
        # Error-reporting refinement: when the oneOf carries a
        # discriminator (the catalog's anyComponent does), surface the
        # matching branch's own errors instead of the generic message.
        # Pass/fail semantics are unchanged — only message selection.
        case discriminated_branch_errors(data, schema, subschemas, results) do
          {:ok, branch_errors} ->
            {@empty_ann, branch_errors}

          :error ->
            miss_errs = results |> Enum.flat_map(&elem(&1, 1)) |> Enum.uniq()

            {@empty_ann,
             miss_errs ++
               [
                 detail(
                   ctx,
                   "invalid_value",
                   "#{repr(data)} is not valid under any of the given schemas"
                 )
               ]}
        end

      _many ->
        {@empty_ann,
         [
           detail(
             ctx,
             "invalid_value",
             "#{repr(data)} is valid under each of the given schemas"
           )
         ]}
    end
  end

  defp eval_one_of(_data, _schema, _ctx), do: {@empty_ann, []}

  # Finds the oneOf branch selected by `discriminator.propertyName` (the
  # branch whose `properties.<name>.const` matches the instance value)
  # and returns that branch's validation errors for better reporting.
  @spec discriminated_branch_errors(term(), map(), [term()], [{annotations(), [Detail.t()]}]) ::
          {:ok, [Detail.t()]} | :error
  defp discriminated_branch_errors(data, %{"discriminator" => disc}, subschemas, results)
       when is_map(disc) do
    with %{"propertyName" => property} when is_binary(property) <- disc,
         {:ok, value} when is_binary(value) <- Map.fetch(data, property),
         {branch_index, _subschema} <-
           Enum.find(Enum.with_index(subschemas), fn {_idx, sub} ->
             branch_const(sub, property) == value
           end),
         {_ann, errs} <- Enum.at(results, branch_index) do
      {:ok, errs}
    else
      _ -> :error
    end
  end

  defp discriminated_branch_errors(_data, _schema, _subschemas, _results), do: :error

  @spec branch_const(term(), String.t()) :: term()
  defp branch_const(sub, property) when is_map(sub) do
    case sub do
      %{"properties" => %{^property => %{"const" => const}}} -> const
      %{"properties" => %{^property => %{"enum" => [const | _]}}} -> const
      _ -> :undefined
    end
  end

  defp branch_const(_sub, _property), do: :undefined

  @spec eval_not(term(), map(), ctx()) :: {annotations(), [Detail.t()]}
  defp eval_not(data, %{"not" => subschema}, ctx) do
    case eval(data, subschema, ctx) do
      {_, []} ->
        {@empty_ann,
         [detail(ctx, "invalid_value", "#{repr(data)} must not be valid under the given schema")]}

      {_, _} ->
        {@empty_ann, []}
    end
  end

  defp eval_not(_data, _schema, _ctx), do: {@empty_ann, []}

  @spec any_of_message(term()) :: String.t()
  defp any_of_message(data),
    do: "#{repr(data)} is not valid under any of the given schemas"

  @spec merge_or_drop(annotations(), annotations(), [Detail.t()]) :: annotations()
  defp merge_or_drop(acc, _sub_ann, errs) when errs != [], do: acc
  defp merge_or_drop(acc, sub_ann, _errs), do: merge_annots(acc, sub_ann)

  # ------------------------------------------------------------- if/then/else --

  @spec eval_if_then_else(term(), map(), ctx()) :: {annotations(), [Detail.t()]}
  defp eval_if_then_else(data, %{"if" => if_schema} = schema, ctx) do
    {_if_ann, if_errs} = eval(data, if_schema, ctx)

    if if_errs == [] do
      case Map.fetch(schema, "then") do
        {:ok, then_schema} -> eval(data, then_schema, ctx)
        :error -> {@empty_ann, []}
      end
    else
      case Map.fetch(schema, "else") do
        {:ok, else_schema} -> eval(data, else_schema, ctx)
        :error -> {@empty_ann, []}
      end
    end
  end

  defp eval_if_then_else(_data, _schema, _ctx), do: {@empty_ann, []}

  # ---------------------------------------------------------------- unevaluated --

  @spec eval_unevaluated(term(), map(), ctx(), annotations()) ::
          {annotations(), [Detail.t()]}
  defp eval_unevaluated(data, schema, ctx, ann) do
    case Map.fetch(schema, "unevaluatedProperties") do
      {:ok, directive} when plain_map?(data) ->
        extras = MapSet.difference(MapSet.new(Map.keys(data)), ann.props)
        apply_unevaluated(data, directive, extras, ctx)

      :error ->
        reject_unsupported_unevaluated_items(schema)
        {@empty_ann, []}

      {:ok, _directive} ->
        # unevaluatedProperties against a non-object instance: no-op.
        {@empty_ann, []}
    end
  end

  @spec apply_unevaluated(map(), term(), MapSet.t(String.t()), ctx()) ::
          {annotations(), [Detail.t()]}
  defp apply_unevaluated(data, directive, extras, ctx) do
    if MapSet.size(extras) == 0 do
      {@empty_ann, []}
    else
      apply_unevaluated_extras(data, directive, extras, ctx)
    end
  end

  @spec apply_unevaluated_extras(map(), term(), MapSet.t(String.t()), ctx()) ::
          {annotations(), [Detail.t()]}
  defp apply_unevaluated_extras(_data, false, extras, ctx) do
    sorted = extras |> MapSet.to_list() |> Enum.sort()
    joined = quote_keys(sorted)
    verb = if length(sorted) == 1, do: "was", else: "were"

    {@empty_ann,
     [
       detail(
         ctx,
         "extra_field",
         "Unevaluated properties are not allowed (#{joined} #{verb} unexpected)"
       )
     ]}
  end

  defp apply_unevaluated_extras(_data, true, extras, _ctx),
    do: {props(MapSet.to_list(extras)), []}

  defp apply_unevaluated_extras(data, directive, extras, ctx) when is_map(directive) do
    Enum.reduce(MapSet.to_list(extras), {props(MapSet.to_list(extras)), []}, fn key, {a, errs} ->
      {_, child_errs} = eval(Map.get(data, key), directive, sub_ctx(ctx, key))
      {a, errs ++ child_errs}
    end)
  end

  @spec reject_unsupported_unevaluated_items(map()) :: :ok
  defp reject_unsupported_unevaluated_items(schema) do
    case Map.fetch(schema, "unevaluatedItems") do
      {:ok, _} ->
        raise ArgumentError,
              "unevaluatedItems is not supported by A2UICore.Schema (no A2UI schema uses it)"

      :error ->
        :ok
    end
  end
end

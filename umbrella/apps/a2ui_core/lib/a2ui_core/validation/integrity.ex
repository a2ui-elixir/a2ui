defmodule A2UICore.Validation.Integrity do
  @moduledoc """
  Payload preflight checks that run before schema validation:
  global nesting depth, nested function-call depth, and JSON-pointer
  path syntax. Ported verbatim from the reference's
  `validate_recursion_and_paths`.

  Limits:

    * `@max_global_depth` (50) — nesting depth of the whole payload.
    * `@max_func_call_depth` (5) — nesting of `call`/`@call`+`args`
      (or v0.8 `functionCall`) structures.

  Path keys checked: `"path"` and `"@path"` (v1.0 binds with `@path`;
  templates and `updateDataModel` use `path`). The relaxed pointer
  pattern allows absolute (`/a/b`) and relative (`a/b`) forms with
  RFC 6901 escapes (`~0`, `~1` only).
  """

  alias A2UICore.Error
  alias A2UICore.Error.Detail

  @moduledoc since: "0.1.0"

  @max_global_depth 50
  @max_func_call_depth 5

  @relaxed_path_pattern Regex.compile!(
                          ~S"^(?:(?:\/(?:[^~\/]|~[01])*)*|(?:[^~\/]|~[01])+(?:\/(?:[^~\/]|~[01])*)*)$",
                          [:unicode]
                        )

  @doc "The global payload nesting limit."
  @spec max_global_depth() :: pos_integer()
  def max_global_depth, do: @max_global_depth

  @doc "The nested function-call limit."
  @spec max_func_call_depth() :: pos_integer()
  def max_func_call_depth, do: @max_func_call_depth

  @doc """
  Traverses a message payload, raising `A2UICore.Error` (category
  `:recursion` or `:validation`) when a limit or path syntax is
  violated. Returns `:ok` otherwise.
  """
  @spec validate_recursion_and_paths!(term()) :: :ok
  def validate_recursion_and_paths!(data), do: traverse(data, 0, 0)

  @doc """
  As `validate_recursion_and_paths!/1`, returning `:ok | {:error, error}`
  instead of raising.
  """
  @spec validate_recursion_and_paths(term()) :: :ok | {:error, Error.t()}
  def validate_recursion_and_paths(data) do
    validate_recursion_and_paths!(data)
    :ok
  rescue
    error in Error -> {:error, error}
  end

  # ------------------------------------------------------------------ core --

  defp traverse(_item, global_depth, _func_depth) when global_depth > @max_global_depth do
    Error.raise!(
      :recursion,
      "RECURSION_LIMIT",
      "Global recursion limit exceeded: Depth > #{@max_global_depth}"
    )
  end

  defp traverse(item, global_depth, func_depth) when is_list(item) do
    Enum.each(item, &traverse(&1, global_depth + 1, func_depth))
  end

  defp traverse(item, global_depth, func_depth) when is_map(item) do
    validate_path_keys!(item)
    traverse_item(item, global_depth, func_depth)
  end

  defp traverse(_item, _global_depth, _func_depth), do: :ok

  defp validate_path_keys!(item) do
    Enum.each(["path", "@path"], fn key -> validate_path_key!(key, Map.get(item, key)) end)
  end

  defp validate_path_key!(key, path) when is_binary(path) do
    if !Regex.match?(@relaxed_path_pattern, path) do
      Error.raise!(
        :validation,
        "invalid_pointer",
        "Invalid path syntax: '#{path}'",
        details: [Detail.new("invalid_pointer", "Invalid path syntax: '#{path}'", key)]
      )
    end
  end

  defp validate_path_key!(_key, _non_string), do: :ok

  defp traverse_item(item, global_depth, func_depth) do
    cond do
      function_call_v0_8?(item) ->
        assert_func_depth!(func_depth)
        traverse(item["functionCall"], global_depth + 1, func_depth + 1)

      function_call_v0_9_plus?(item) ->
        assert_func_depth!(func_depth)

        Enum.each(item, fn
          {"args", value} -> traverse(value, global_depth + 1, func_depth + 1)
          {_key, value} -> traverse(value, global_depth + 1, func_depth)
        end)

      true ->
        Enum.each(item, fn {_key, value} -> traverse(value, global_depth + 1, func_depth) end)
    end
  end

  defp function_call_v0_8?(item) do
    is_map(item["functionCall"])
  end

  defp function_call_v0_9_plus?(item) do
    Map.has_key?(item, "args") and (Map.has_key?(item, "call") or Map.has_key?(item, "@call"))
  end

  defp assert_func_depth!(func_depth) when func_depth >= @max_func_call_depth do
    Error.raise!(
      :recursion,
      "RECURSION_LIMIT",
      "Recursion limit exceeded: functionCall depth > #{@max_func_call_depth}"
    )
  end

  defp assert_func_depth!(_func_depth), do: :ok
end

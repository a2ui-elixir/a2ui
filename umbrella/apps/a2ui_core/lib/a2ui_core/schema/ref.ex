defmodule A2UICore.Schema.Ref do
  @moduledoc false

  # `$ref` resolution against a registry of named documents.
  #
  # Supported forms (the ones the A2UI schemas emit):
  #
  #   * "#/components/Text"           local pointer into the root document
  #   * "common_types.json#/$defs/X"  external doc + pointer
  #   * "catalog.json"                external doc, no pointer
  #   * "https://a2ui.org/…"          absolute URL (exact key or basename match)
  #
  # This module is pure: it neither owns nor mutates the caller's
  # evaluation context; `resolve/4` returns the resolved root document (so
  # the caller can rebind local refs to it) and the target subschema.

  alias A2UICore.Error
  alias A2UICore.Pointer

  @max_ref_depth 64

  @type registry :: %{optional(String.t()) => A2UICore.Schema.schema()}

  @doc """
  Resolves `ref` given the current `root` document, `registry`, and
  `ref_depth`.

  Returns `{:ok, resolved_root, subschema}` — where `resolved_root` is the
  document the ref landed in (callers rebind local `#/...` refs to it) —
  or `{:error, error}` when the target document or pointer is missing or
  the recursion limit is hit.
  """
  @spec resolve(String.t(), A2UICore.Schema.schema(), registry(), non_neg_integer()) ::
          {:ok, A2UICore.Schema.schema(), A2UICore.Schema.schema()} | {:error, Error.t()}
  def resolve(ref, root, registry, ref_depth) when is_binary(ref) do
    if ref_depth >= @max_ref_depth do
      {:error,
       Error.new(
         :validation,
         "invalid_reference",
         "$ref recursion limit (#{@max_ref_depth}) exceeded at '#{ref}'"
       )}
    else
      do_resolve(ref, root, registry)
    end
  end

  @spec do_resolve(String.t(), A2UICore.Schema.schema(), registry()) ::
          {:ok, A2UICore.Schema.schema(), A2UICore.Schema.schema()} | {:error, Error.t()}
  defp do_resolve(ref, root, registry) do
    {target, pointer} = split_ref(ref)

    with {:ok, doc} <- resolve_doc(target, root, registry),
         {:ok, sub} <- resolve_pointer(doc, pointer, ref) do
      {:ok, doc, sub}
    end
  end

  @spec split_ref(String.t()) :: {String.t(), String.t()}
  defp split_ref(ref) do
    case String.split(ref, "#", parts: 2) do
      [target] -> {target, ""}
      [target, pointer] -> {target, pointer}
    end
  end

  @spec resolve_doc(String.t(), A2UICore.Schema.schema(), registry()) ::
          {:ok, A2UICore.Schema.schema()} | {:error, Error.t()}
  defp resolve_doc("", root, _registry), do: {:ok, root}

  defp resolve_doc(target, _root, registry) do
    case Map.fetch(registry, target) do
      {:ok, doc} ->
        {:ok, doc}

      :error ->
        case registry_by_basename(registry, target) do
          nil ->
            {:error,
             Error.new(
               :validation,
               "invalid_reference",
               "Cannot resolve $ref '#{target}': no such document in registry"
             )}

          doc ->
            {:ok, doc}
        end
    end
  end

  @spec registry_by_basename(registry(), String.t()) :: A2UICore.Schema.schema() | nil
  defp registry_by_basename(registry, target) do
    Enum.find_value(registry, fn {key, doc} ->
      if base_name(key) == base_name(target), do: doc
    end)
  end

  @spec base_name(String.t()) :: String.t() | nil
  defp base_name(name) do
    name
    |> String.trim_leading("https://")
    |> String.trim_leading("http://")
    |> String.split("/")
    |> List.last()
  end

  @spec resolve_pointer(A2UICore.Schema.schema(), String.t(), String.t()) ::
          {:ok, A2UICore.Schema.schema()} | {:error, Error.t()}
  defp resolve_pointer(doc, "", _ref), do: {:ok, doc}

  defp resolve_pointer(doc, "/" <> _ = pointer, ref) do
    tokens =
      pointer
      |> String.trim_leading("/")
      |> String.split("/")
      |> Enum.map(&Pointer.unescape_segment/1)

    case fetch(doc, tokens) do
      {:ok, sub} ->
        {:ok, sub}

      :error ->
        {:error,
         Error.new(
           :validation,
           "invalid_reference",
           "Cannot resolve $ref '#{ref}': JSON pointer '#{pointer}' not found"
         )}
    end
  end

  defp resolve_pointer(_doc, _non_root_pointer, ref) do
    {:error,
     Error.new(
       :validation,
       "invalid_reference",
       "Cannot resolve $ref '#{ref}': only root-relative JSON pointers are supported"
     )}
  end

  @spec fetch(term(), [String.t()]) :: {:ok, term()} | :error
  defp fetch(value, []), do: {:ok, value}

  defp fetch(value, [token | rest]) when is_map(value) do
    case Map.fetch(value, token) do
      {:ok, inner} -> fetch(inner, rest)
      :error -> :error
    end
  end

  defp fetch(value, [token | rest]) when is_list(value) do
    with true <- Pointer.array_index?(token),
         idx <- String.to_integer(token),
         true <- idx < length(value) do
      fetch(Enum.at(value, idx), rest)
    else
      _ -> :error
    end
  end

  defp fetch(_value, _tokens), do: :error
end

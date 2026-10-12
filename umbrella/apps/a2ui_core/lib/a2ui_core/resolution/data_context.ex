defmodule A2UICore.Resolution.DataContext do
  @moduledoc """
  A data-binding scope: the absolute path relative bindings resolve
  against, plus the collection-template iteration index.

  The root scope is `"/"`. A component rendered for item `2` of a
  `/items` template runs in the nested scope `"/items/2/"`, so its
  relative path `name` resolves to `/items/2/name`. Scopes are plain
  values; evaluating bindings against a `A2UICore.State.DataModel` builds
  on them (see the dynamic-value functions).

  Path resolution follows the reference:

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
  """

  @moduledoc since: "0.1.0"

  defstruct path: "/", index: nil, parent: nil

  @type t :: %__MODULE__{path: String.t(), index: non_neg_integer() | nil, parent: t() | nil}

  @doc """
  Creates a root scope at `path` (default `"/"`). The stored path always
  ends with a slash.
  """
  @spec new(String.t()) :: t()
  def new(path \\ "/") when is_binary(path), do: %__MODULE__{path: with_trailing_slash(path)}

  @doc """
  Creates a child scope for `relative_path` (a leading `/` is ignored),
  optionally recording the iteration `index` of a collection template.
  """
  @spec nested(t(), String.t(), non_neg_integer() | nil) :: t()
  def nested(%__MODULE__{} = context, relative_path, index \\ nil)
      when is_binary(relative_path) do
    relative = String.replace_prefix(relative_path, "/", "")

    %__MODULE__{
      path: with_trailing_slash(context.path <> relative),
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

  defp with_trailing_slash(path) do
    if String.ends_with?(path, "/"), do: path, else: path <> "/"
  end
end

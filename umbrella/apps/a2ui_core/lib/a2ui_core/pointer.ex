defmodule A2UICore.Pointer do
  @moduledoc """
  RFC 6901 JSON Pointer parsing, building, and resolution.

  Matches the reference implementation exactly:

  * `"/"` or `""` parse to the root (empty token list).
  * Empty segments are dropped, so `"//a///b//"` ⇔ `"/a/b"`.
  * Unescape order is `~1` → `/` then `~0` → `~` (so `"~01"` decodes to `"~1"`).
  * Forbidden segments after unescaping: `"__proto__"`, `"constructor"`,
    `"prototype"`.
  * Array indices follow the RFC §4 numeric rule: `0` or non-zero-leading
    digits only (`"01"` is **not** an index).
  * Maximum array index `10_000` guards against OOM/DoS by construction.

  This module only handles pointer parsing/building; the store that
  enforces traversal rules lives in `A2UICore.State.DataModel`.
  """

  alias A2UICore.Error

  @moduledoc since: "0.1.0"

  @forbidden_segments MapSet.new(["__proto__", "constructor", "prototype"])
  @numeric_pattern ~r/^(?:0|[1-9][0-9]*)$/
  @max_array_index 10_000

  @typedoc "One segment of a parsed pointer, as stored after unescape."
  @type token :: String.t()

  @doc """
  The forbidden path segments (after unescaping), as a `MapSet`.

  These guard against prototype pollution.
  """
  @spec forbidden_segments() :: MapSet.t(String.t())
  def forbidden_segments, do: @forbidden_segments

  @doc """
  The maximum allowed array index (inclusive).
  """
  @spec max_array_index() :: pos_integer()
  def max_array_index, do: @max_array_index

  @doc """
  True if `segment` can be used as an array index per RFC 6901 §4 —
  i.e. either `"0"` or a positive integer with no leading zeros.
  """
  @spec array_index?(term()) :: boolean()
  def array_index?(segment), do: is_binary(segment) and Regex.match?(@numeric_pattern, segment)

  @doc """
  Parses a pointer string into its segments, unescaping them.

  Returns `{:ok, tokens}` or `{:error, %A2UICore.Error{}}` with category
  `:data` if a segment is in the forbidden set or `path` is invalid.

  ## Examples

      iex> A2UICore.Pointer.parse("/user/name")
      {:ok, ["user", "name"]}
      iex> A2UICore.Pointer.parse("/a~1b/~0c")
      {:ok, ["a/b", "~c"]}
      iex> A2UICore.Pointer.parse("/")
      {:ok, []}
      iex> A2UICore.Pointer.parse("")
      {:ok, []}
      iex> {:error, error} = A2UICore.Pointer.parse("/__proto__")
      iex> error.category
      :data
      iex> error.code
      "DATA_ERROR"
  """
  @spec parse(term()) :: {:ok, [token()]} | {:error, Error.t()}
  def parse(path) when not is_binary(path),
    do: {:error, Error.new(:data, "DATA_ERROR", "Path cannot be null or not a string.")}

  def parse(path) when path in ["", "/"], do: {:ok, []}

  def parse(path) do
    tokens =
      path
      |> String.split("/")
      |> Enum.reject(&(&1 == ""))
      |> Enum.map(&unescape_segment/1)

    case Enum.find(tokens, &MapSet.member?(@forbidden_segments, &1)) do
      nil ->
        {:ok, tokens}

      bad ->
        {:error,
         Error.new(:data, "DATA_ERROR", "Forbidden path segment '#{bad}' in path '#{path}'.",
           path: path
         )}
    end
  end

  @doc """
  Builds an absolute pointer string from unescaped tokens (inverse of
  `parse/1`).
  """
  @spec build([token()]) :: String.t()
  def build([]), do: "/"

  def build(tokens) when is_list(tokens) do
    "/" <> Enum.map_join(tokens, "/", &escape_segment/1)
  end

  @doc """
  Resolves `path` against `context_path`:

      resolve("/user", anything)      → "/user"
      resolve("name", "/user")       → "/user/name"
      resolve("name", "/")           → "/name"
      resolve("name", nil)           → "/name"

  This is the simple client-scope join rule from the reference. The
  collection-scope semantics are in `A2UICore.Resolution.DataContext`.
  """
  @spec resolve(String.t(), String.t() | nil) :: String.t()
  def resolve(path, context_path \\ nil)

  def resolve(<<"/", _::binary>> = absolute, _), do: absolute

  def resolve(path, nil), do: "/" <> path

  def resolve(path, context_path) do
    separator = if String.ends_with?(context_path, "/"), do: "", else: "/"
    context_path <> separator <> path
  end

  @doc false
  @spec escape_segment(String.t()) :: String.t()
  def escape_segment(segment) do
    segment |> String.replace("~", "~0") |> String.replace("/", "~1")
  end

  @doc false
  @spec unescape_segment(String.t()) :: String.t()
  def unescape_segment(segment) do
    segment |> String.replace("~1", "/") |> String.replace("~0", "~")
  end
end

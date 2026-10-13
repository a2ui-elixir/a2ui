defmodule A2UICore.Resolution.Binding do
  @moduledoc """
  A resolved dynamic property: the value it currently holds and, when the
  component bound it to a data path, the absolute path a write goes to.

  A literal, a function call and a binding that failed to resolve are
  read-only; a `{"path": …}` binding (`{"@path": …}` in v1.0) is
  writable.

      iex> A2UICore.Resolution.Binding.writable?(%A2UICore.Resolution.Binding{value: "Ada", path: "/user/name"})
      true
      iex> A2UICore.Resolution.Binding.writable?(%A2UICore.Resolution.Binding{value: "Ada"})
      false
  """

  @moduledoc since: "0.1.0"

  defstruct value: nil, path: nil

  @type t :: %__MODULE__{value: term(), path: String.t() | nil}

  @doc "Whether a write through the binding reaches the data model."
  @spec writable?(t()) :: boolean()
  def writable?(%__MODULE__{path: path}), do: is_binary(path)
end

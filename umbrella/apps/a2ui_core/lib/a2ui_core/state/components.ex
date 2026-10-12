defmodule A2UICore.State.Components do
  @moduledoc """
  The set of components on a surface, keyed by id.

  An immutable collection: every function returns a new value. Adding an
  id that already exists is a `:state` error (replacing is `put/2`);
  removing an absent id is a no-op, as in the reference.

  Iteration (`to_list/1`, `ids/1`) is in sorted id order, which keeps
  graph validation deterministic.

      iex> alias A2UICore.State.{Component, Components}
      iex> {:ok, set} = Components.new() |> Components.add(Component.new("root", "Column"))
      iex> Components.has?(set, "root")
      true
      iex> {:error, error} = Components.add(set, Component.new("root", "Text"))
      iex> error.message
      "Component with id 'root' already exists."
  """

  alias A2UICore.Error
  alias A2UICore.State.Component

  @moduledoc since: "0.1.0"

  defstruct items: %{}

  @type t :: %__MODULE__{items: %{optional(String.t()) => Component.t()}}

  @doc "An empty set."
  @spec new() :: t()
  def new, do: %__MODULE__{}

  @doc "Builds a set from components, the last one winning on a repeated id."
  @spec from_list([Component.t()]) :: t()
  def from_list(components),
    do: %__MODULE__{items: Map.new(components, &{&1.id, &1})}

  @doc "Adds a component; an existing id is a `:state` error."
  @spec add(t(), Component.t()) :: {:ok, t()} | {:error, Error.t()}
  def add(%__MODULE__{items: items} = set, %Component{id: id} = component) do
    if Map.has_key?(items, id) do
      {:error,
       Error.new(:state, "STATE_ERROR", "Component with id '#{id}' already exists.",
         path: "components.#{id}"
       )}
    else
      {:ok, %{set | items: Map.put(items, id, component)}}
    end
  end

  @doc "Adds or replaces a component."
  @spec put(t(), Component.t()) :: t()
  def put(%__MODULE__{items: items} = set, %Component{id: id} = component),
    do: %{set | items: Map.put(items, id, component)}

  @doc "Removes a component (an absent id is ignored)."
  @spec remove(t(), String.t()) :: t()
  def remove(%__MODULE__{items: items} = set, id), do: %{set | items: Map.delete(items, id)}

  @doc "The component with `id`, or `nil`."
  @spec get(t(), String.t()) :: Component.t() | nil
  def get(%__MODULE__{items: items}, id), do: Map.get(items, id)

  @doc "Whether a component with `id` exists."
  @spec has?(t(), String.t()) :: boolean()
  def has?(%__MODULE__{items: items}, id), do: Map.has_key?(items, id)

  @doc "The number of components."
  @spec size(t()) :: non_neg_integer()
  def size(%__MODULE__{items: items}), do: map_size(items)

  @doc "The component ids, sorted."
  @spec ids(t()) :: [String.t()]
  def ids(%__MODULE__{items: items}), do: items |> Map.keys() |> Enum.sort()

  @doc "The components, sorted by id."
  @spec to_list(t()) :: [Component.t()]
  def to_list(%__MODULE__{items: items}),
    do: items |> Enum.sort_by(&elem(&1, 0)) |> Enum.map(&elem(&1, 1))

  @doc """
  The component wire objects, sorted by id.
  """
  @spec trees(t()) :: [map()]
  def trees(%__MODULE__{} = set), do: set |> to_list() |> Enum.map(&Component.tree/1)
end

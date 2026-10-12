defmodule A2UICore.State.SurfaceGroup do
  @moduledoc """
  All live surfaces of a session, keyed by surface id.

  Lifecycle operations return the updated group and the effects a host
  may react to (`{:surface_created, id}`, `{:surface_deleted, id}`).
  Adding an existing id and deleting an unknown id are no-ops with no
  effects, as in the reference.

      iex> alias A2UICore.State.{Surface, SurfaceGroup}
      iex> {group, [{:surface_created, "main"}]} =
      ...>   SurfaceGroup.new() |> SurfaceGroup.add(Surface.new("main"))
      iex> SurfaceGroup.ids(group)
      ["main"]
      iex> {group, [{:surface_deleted, "main"}]} = SurfaceGroup.delete(group, "main")
      iex> SurfaceGroup.ids(group)
      []
  """

  alias A2UICore.State.Surface

  @moduledoc since: "0.1.0"

  defstruct surfaces: %{}

  @type t :: %__MODULE__{surfaces: %{optional(String.t()) => Surface.t()}}

  @type effect :: {:surface_created, String.t()} | {:surface_deleted, String.t()}

  @doc "An empty group."
  @spec new() :: t()
  def new, do: %__MODULE__{}

  @doc "The surface with `id`, or `nil`."
  @spec get(t(), String.t()) :: Surface.t() | nil
  def get(%__MODULE__{surfaces: surfaces}, id), do: Map.get(surfaces, id)

  @doc "Whether a surface with `id` exists."
  @spec has?(t(), String.t()) :: boolean()
  def has?(%__MODULE__{surfaces: surfaces}, id), do: Map.has_key?(surfaces, id)

  @doc "The surface ids, sorted."
  @spec ids(t()) :: [String.t()]
  def ids(%__MODULE__{surfaces: surfaces}), do: surfaces |> Map.keys() |> Enum.sort()

  @doc "The surfaces, sorted by id."
  @spec to_list(t()) :: [Surface.t()]
  def to_list(%__MODULE__{surfaces: surfaces}),
    do: surfaces |> Enum.sort_by(&elem(&1, 0)) |> Enum.map(&elem(&1, 1))

  @doc "Adds a surface; an id already present is left untouched."
  @spec add(t(), Surface.t()) :: {t(), [effect()]}
  def add(%__MODULE__{surfaces: surfaces} = group, %Surface{id: id} = surface) do
    if Map.has_key?(surfaces, id) do
      {group, []}
    else
      {%{group | surfaces: Map.put(surfaces, id, surface)}, [{:surface_created, id}]}
    end
  end

  @doc """
  Replaces an existing surface's state (after a data or component
  update). An unknown id is ignored.
  """
  @spec update(t(), Surface.t()) :: t()
  def update(%__MODULE__{surfaces: surfaces} = group, %Surface{id: id} = surface) do
    if Map.has_key?(surfaces, id),
      do: %{group | surfaces: Map.put(surfaces, id, surface)},
      else: group
  end

  @doc "Deletes and disposes a surface; an unknown id is ignored."
  @spec delete(t(), String.t()) :: {t(), [effect()]}
  def delete(%__MODULE__{surfaces: surfaces} = group, id) do
    case Map.pop(surfaces, id) do
      {nil, _} ->
        {group, []}

      {surface, rest} ->
        _disposed = Surface.dispose(surface)
        {%{group | surfaces: rest}, [{:surface_deleted, id}]}
    end
  end

  @doc "Deletes every surface."
  @spec dispose(t()) :: {t(), [effect()]}
  def dispose(%__MODULE__{} = group) do
    Enum.reduce(ids(group), {group, []}, fn id, {group, effects} ->
      {group, more} = delete(group, id)
      {group, effects ++ more}
    end)
  end
end

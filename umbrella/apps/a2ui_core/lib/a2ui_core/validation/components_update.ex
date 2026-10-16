defmodule A2UICore.Validation.ComponentsUpdate do
  @moduledoc """
  Validates a batch of incoming components against the surface they
  update, before any of them is committed.

  The checks run in the reference's order and stop at the first group
  that fails:

    1. ids are unique within the batch (`:integrity`, detail code
       `duplicate_id`);
    2. every component satisfies its catalog (`:validation`; the details
       of all failing components are reported together, and the message
       reads `Validation failed for component 'Type': path: message`);
    3. the *prospective* graph — the surface's components with the batch
       laid over them — satisfies the catalog's composition constraints,
       has its root, resolves every reference, and is acyclic and fully
       reachable (see `A2UICore.Validation.Topology`).

  Which checks apply is decided by the `A2UICore.Validation.Config`.

  From v1.0 a function call that names no `catalogId` runs in the
  surface's default catalog; a component in another catalog is validated
  with its `catalogId`, so the validator leaves those calls to the
  processor's nested-call pass (`A2UICore.Validation.NestedCalls`).
  """

  alias A2UICore.Catalog
  alias A2UICore.Error
  alias A2UICore.Error.Detail
  alias A2UICore.State.{Component, Components}
  alias A2UICore.Validation.{Config, Payload, Topology}

  @moduledoc since: "0.1.0"

  @typedoc "Maps a component to the catalog it is validated against."
  @type catalog_for :: (Component.t() -> Catalog.t() | nil)

  @doc """
  Validates `incoming` against `existing`. Returns `:ok` or
  `{:error, %A2UICore.Error{}}`; nothing is changed either way.

  Options: `:default_catalog_id` — the surface's default catalog (`nil`
  when it has none).
  """
  @spec validate(Components.t(), [Component.t()], catalog_for(), Config.t(), keyword()) ::
          :ok | {:error, Error.t()}
  def validate(%Components{} = existing, incoming, catalog_for, %Config{} = config, options \\ [])
      when is_list(incoming) and is_function(catalog_for, 1) do
    with :ok <- unique_ids(incoming),
         :ok <- validate_components(incoming, catalog_for, config, options[:default_catalog_id]) do
      validate_graph(
        Enum.reduce(incoming, existing, &Components.put(&2, &1)),
        catalog_for,
        config
      )
    end
  end

  @doc """
  What a catalog knows about a component, in the shape
  `A2UICore.Validation.Topology` consumes.
  """
  @spec info(Component.t(), Catalog.t() | nil) :: Component.info() | nil
  def info(_component, nil), do: nil

  def info(%Component{type: type}, %Catalog{} = catalog) do
    case Catalog.get_component(catalog, type) do
      nil ->
        %{ref_spec: Catalog.ref_spec(catalog, type)}

      component ->
        %{
          ref_spec: Catalog.ref_spec(catalog, type),
          allowed_parents: component.allowed_parents,
          allowed_children: component.allowed_children
        }
    end
  end

  # -- batch --------------------------------------------------------------------

  defp unique_ids(incoming) do
    incoming
    |> Enum.reduce_while(MapSet.new(), fn %Component{id: id}, seen ->
      if MapSet.member?(seen, id), do: {:halt, id}, else: {:cont, MapSet.put(seen, id)}
    end)
    |> case do
      %MapSet{} -> :ok
      duplicate -> duplicate_error(duplicate)
    end
  end

  defp duplicate_error(id) do
    message = "Duplicate component ID '#{id}' in update payload."
    path = "components.#{id}"

    {:error,
     Error.new(:integrity, "INTEGRITY_ERROR", message,
       path: path,
       details: [Detail.new("duplicate_id", message, path)]
     )}
  end

  defp validate_components(incoming, catalog_for, config, default_id) do
    failures =
      for component <- incoming,
          catalog = catalog_for.(component),
          catalog != nil,
          {:error, %Error{details: details}} <-
            [Payload.validate_component(catalog, tree(component, catalog, default_id), config)],
          do: {component, details}

    case failures do
      [] -> :ok
      failures -> {:error, failure(failures)}
    end
  end

  defp tree(component, catalog, default_id) do
    tree = Component.tree(component)

    if Catalog.v1?(catalog) and component.catalog_id != default_id,
      do: Map.put(tree, "catalogId", catalog.catalog_id),
      else: tree
  end

  defp failure(failures) do
    summary =
      Enum.map_join(failures, "\n", fn {component, details} ->
        "#{label(component)}: " <> Enum.map_join(details, "\n", &"#{&1.path}: #{&1.message}")
      end)

    Error.new(:validation, "VALIDATION_FAILED", "Validation failed for component #{summary}",
      details: Enum.flat_map(failures, &elem(&1, 1))
    )
  end

  defp label(%Component{type: type}) when type not in [nil, ""], do: "'#{type}'"
  defp label(%Component{id: id}), do: "id '#{id}'"

  # -- graph --------------------------------------------------------------------

  defp validate_graph(prospective, catalog_for, config) do
    info_fun = fn component -> info(component, catalog_for.(component)) end

    with :ok <- Topology.validate_composition(prospective, info_fun),
         :ok <- Topology.validate_integrity(prospective, info_fun, config),
         {:ok, _reachable} <- Topology.analyze(prospective, info_fun, config) do
      :ok
    end
  end
end

defmodule A2UIAgent.PayloadValidator do
  @moduledoc """
  Checks a payload an agent is about to send the way a renderer holding
  the same catalogs would.

      :ok = A2UIAgent.PayloadValidator.validate(catalogs, messages)

  The check is stateless: it sees one payload, with no record of earlier
  ones.

    * A surface the payload creates is checked in full: its components
      must be valid and reachable from the root, and their references
      must resolve once every message of the payload is applied (a
      component may name a child that a later message adds).
    * A surface the payload only updates may already hold components, so
      references to components outside the payload and a missing root
      are accepted. Its components must still be valid in a catalog that
      defines all of them; the surface passes if one such catalog accepts
      it. When the caller knows the catalog an earlier payload created
      the surface with (`:surface_catalog_ids`), only that one is tried.

  Every message must state a `version` its catalogs accept: `v0.9` or
  `v0.9.1` for v0.9 catalogs, `v1.0` for v1.0 catalogs.

  Failures are `A2UICore.Error`s: category `:validation` (or one of its
  refinements, `:integrity` and `:recursion`) for a payload a renderer
  would reject, `:catalog` for catalogs that cannot be used together.
  """

  alias A2UIAgent.Catalogs
  alias A2UICore.{Catalog, Error, Processor, Version}
  alias A2UICore.State.{Component, Surface}
  alias A2UICore.Validation.{ComponentsUpdate, Config, Topology}

  @moduledoc since: "0.1.0"

  @create_actions ["createSurface"]
  @update_actions ["updateComponents", "updateDataModel", "deleteSurface"]
  @refinements [:validation, :integrity, :recursion]

  @doc """
  Validates `payload` (one message or a list of messages) against
  `catalogs`. Option: `:surface_catalog_ids` — `%{surface_id =>
  catalog_id}` for surfaces earlier payloads created.
  """
  @spec validate([Catalog.t()], term(), keyword()) :: :ok | {:error, Error.t()}
  def validate(catalogs, payload, options \\ [])

  def validate([], _payload, _options),
    do: {:error, catalog_error("Validating a payload requires at least one catalog.")}

  def validate([first | _] = catalogs, payload, options) do
    with :ok <- check_versions(catalogs),
         {:ok, messages} <- extract(payload),
         :ok <- check_messages(messages, first) do
      {checked, updated} = split(messages)
      known = Keyword.get(options, :surface_catalog_ids) || %{}

      with :ok <- check_created(catalogs, checked),
           do: check_all_updated(catalogs, updated, known)
    end
  end

  # -- versions ---------------------------------------------------------------------

  defp accepted_versions(%Catalog{protocol_version: version}) do
    case Version.to_protocol_version(version) do
      {:ok, "v1.0"} -> ["v1.0"]
      _v09 -> ["v0.9", "v0.9.1"]
    end
  end

  defp check_versions([first | rest]) do
    case Enum.find(rest, &(accepted_versions(&1) != accepted_versions(first))) do
      nil ->
        :ok

      other ->
        {:error,
         catalog_error(
           "The catalogs target incompatible protocol versions: '#{first.catalog_id}' " <>
             "targets #{Catalogs.protocol_version(first)} and '#{other.catalog_id}' targets " <>
             "#{Catalogs.protocol_version(other)}."
         )}
    end
  end

  # -- messages ---------------------------------------------------------------------

  defp extract(payload) do
    messages = if is_list(payload), do: payload, else: [payload]

    case Enum.find_index(messages, &(not is_map(&1))) do
      nil -> {:ok, messages}
      index -> {:error, validation_error("Message #{index} is not a JSON object.")}
    end
  end

  defp check_messages(messages, %Catalog{} = catalog) do
    accepted = accepted_versions(catalog)
    version = Catalogs.protocol_version(catalog)

    messages
    |> Enum.with_index()
    |> Enum.find_value(:ok, fn {message, index} ->
      case check_version(message, index, version, accepted) do
        :ok -> empty_components(message, index)
        error -> error
      end
    end)
  end

  defp check_version(message, index, version, accepted) do
    case Map.get(message, "version") do
      nil ->
        {:error,
         validation_error(
           "Message #{index} states no version, which #{version} messages require."
         )}

      stated ->
        if stated in accepted do
          :ok
        else
          {:error,
           validation_error(
             "Message #{index} states version #{inspect(stated)}, but the catalogs target " <>
               "#{version}, whose messages state " <>
               Enum.map_join(accepted, " or ", &inspect/1) <> "."
           )}
        end
    end
  end

  defp empty_components(message, index) do
    Enum.find_value(["updateComponents", "createSurface"], fn action ->
      case message[action] do
        %{"components" => []} ->
          {:error,
           validation_error("Message #{index} (#{action}) has an empty 'components' list.")}

        _other ->
          nil
      end
    end)
  end

  # Messages for surfaces the payload creates (or that target no surface)
  # are checked together; the others are grouped by surface.
  defp split(messages) do
    created =
      for message <- messages,
          {id, true} <- [target(message)],
          id != nil,
          into: MapSet.new(),
          do: id

    {checked, updated} =
      Enum.reduce(messages, {[], []}, fn message, {checked, updated} ->
        case updated_surface(message, created) do
          nil -> {[message | checked], updated}
          id -> {checked, add_update(updated, id, message)}
        end
      end)

    {Enum.reverse(checked),
     updated |> Enum.reverse() |> Enum.map(fn {id, ms} -> {id, Enum.reverse(ms)} end)}
  end

  # The surface a message updates without the payload creating it.
  defp updated_surface(message, created) do
    case target(message) do
      {nil, _creates} -> nil
      {id, _creates} -> if MapSet.member?(created, id), do: nil, else: id
    end
  end

  defp add_update(updated, id, message) do
    if List.keymember?(updated, id, 0),
      do:
        List.keyreplace(updated, id, 0, {id, [message | elem(List.keyfind(updated, id, 0), 1)]}),
      else: [{id, [message]} | updated]
  end

  # A message holding more than one action targets no surface, so it is
  # checked in full and the processor rejects it.
  defp target(message) do
    case Enum.filter(@create_actions ++ @update_actions, &Map.has_key?(message, &1)) do
      [action] ->
        case message[action] do
          %{"surfaceId" => id} when is_binary(id) -> {id, action in @create_actions}
          _other -> {nil, false}
        end

      _none_or_several ->
        {nil, false}
    end
  end

  # -- created surfaces -------------------------------------------------------------

  defp check_created(_catalogs, []), do: :ok

  defp check_created(catalogs, messages) do
    with {:ok, processor} <- process(catalogs, messages),
         do: processor |> Processor.surfaces() |> check_topologies()
  end

  defp check_topologies([]), do: :ok

  defp check_topologies([surface | rest]),
    do: with(:ok <- check_topology(surface), do: check_topologies(rest))

  defp check_topology(%Surface{} = surface) do
    default = Surface.default_catalog(surface)

    info_fun = fn %Component{catalog_id: id} = component ->
      ComponentsUpdate.info(component, Map.get(surface.catalogs, id) || default)
    end

    case Topology.validate(surface.components, info_fun, Config.new(root_id: surface.root_id)) do
      :ok -> :ok
      {:error, error} -> {:error, as_validation(error)}
    end
  end

  # -- updated surfaces -------------------------------------------------------------

  defp check_all_updated(_catalogs, [], _known), do: :ok

  defp check_all_updated(catalogs, [{surface_id, messages} | rest], known) do
    with :ok <- check_updated(catalogs, surface_id, messages, known[surface_id]),
         do: check_all_updated(catalogs, rest, known)
  end

  defp check_updated(catalogs, surface_id, messages, known_id) do
    with {:ok, candidates} <- candidates(catalogs, surface_id, messages, known_id),
         do: try_candidates(catalogs, surface_id, messages, candidates, nil)
  end

  # Passes once a candidate catalog accepts the surface; otherwise fails
  # with the first candidate's error.
  defp try_candidates(_catalogs, _surface_id, _messages, [], first_error), do: first_error

  defp try_candidates(catalogs, surface_id, messages, [catalog | rest], first_error) do
    creation = %{
      "version" => hd(messages)["version"],
      "createSurface" => %{"surfaceId" => surface_id, "catalogId" => catalog.catalog_id}
    }

    case process(catalogs, [creation | messages]) do
      {:ok, _processor} -> :ok
      error -> try_candidates(catalogs, surface_id, messages, rest, first_error || error)
    end
  end

  defp candidates(catalogs, surface_id, _messages, known_id) when is_binary(known_id) do
    case Enum.filter(catalogs, &(&1.catalog_id == known_id)) do
      [] ->
        {:error,
         validation_error(
           "Surface '#{surface_id}' uses catalog '#{known_id}', which isn't one of the " <>
             "active catalogs."
         )}

      found ->
        {:ok, found}
    end
  end

  defp candidates(catalogs, _surface_id, messages, nil) do
    types = component_types(messages)

    case Enum.filter(catalogs, fn c -> Enum.all?(types, &Catalog.get_component(c, &1)) end) do
      [] -> {:ok, [hd(catalogs)]}
      found -> {:ok, found}
    end
  end

  # Components that name a catalog of their own do not use the surface's.
  defp component_types(messages) do
    for %{"updateComponents" => %{"components" => components}} when is_list(components) <-
          messages,
        %{"component" => type} = component when is_binary(type) <- components,
        not Map.has_key?(component, "catalogId"),
        uniq: true,
        do: type
  end

  # -- processing -------------------------------------------------------------------

  defp process(catalogs, messages) do
    config =
      Config.new(
        allow_dangling_references: true,
        allow_missing_root: true,
        allow_orphan_components: true
      )

    case Processor.process(Processor.new(catalogs, validation: config), messages) do
      {:ok, processor, _effects} -> {:ok, processor}
      {:error, error, _processor} -> {:error, as_validation(error)}
    end
  end

  # Errors of other kinds, such as a catalog the payload names but the
  # catalogs do not hold, come from the payload too.
  defp as_validation(%Error{category: category} = error) when category in @refinements,
    do: error

  defp as_validation(%Error{} = error), do: %{error | category: :validation}

  defp catalog_error(message), do: Error.new(:catalog, "CATALOG_ERROR", message)
  defp validation_error(message), do: Error.new(:validation, "VALIDATION_FAILED", message)
end

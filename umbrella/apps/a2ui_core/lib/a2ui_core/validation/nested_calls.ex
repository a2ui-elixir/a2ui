defmodule A2UICore.Validation.NestedCalls do
  @moduledoc """
  Checks the function calls nested in a v1.0 `updateComponents` batch
  against the catalogs they run in, before anything is committed.

  From v1.0 a call runs in the catalog it names, or else in the surface's
  default catalog, which need not be the catalog of the component that
  holds it. Every call's catalog must resolve on the surface (a
  `:catalog` error otherwise, raised at once, even without a validation
  configuration, since the call could never run). With a configuration,
  the arguments of a call that runs outside its component's catalog are
  validated here; component validation
  (`A2UICore.Validation.Payload.validate_component/3`) checks the others.

  Calls to system functions (`@index`) belong to no catalog and are
  skipped; the calls in their arguments are still checked.
  """

  alias A2UICore.{Catalog, Error, Version}
  alias A2UICore.Error.Detail
  alias A2UICore.State.{Component, Surface}
  alias A2UICore.Validation.{Config, Payload}

  @moduledoc since: "0.1.0"

  @doc """
  Checks the calls nested in `components` (state components bound for
  `surface`). `catalogs` are all the catalogs the processor holds, which
  tell a catalog the surface cannot use apart from one that does not
  exist. `config` is the validation configuration, or `nil`.
  """
  @spec check(Surface.t(), [Component.t()], [Catalog.t()], Config.t() | nil) ::
          :ok | {:error, Error.t()}
  def check(%Surface{} = surface, components, catalogs, config) do
    state = %{surface: surface, catalogs: catalogs, config: config, details: [], summaries: []}

    result =
      Enum.reduce_while(components, {:ok, state}, fn component, {:ok, state} ->
        component.props
        |> Enum.sort_by(&elem(&1, 0))
        |> Enum.reduce_while({:ok, state}, fn {key, value}, {:ok, state} ->
          continue(visit(component, value, key, state))
        end)
        |> continue()
      end)

    case result do
      {:ok, %{details: []}} ->
        :ok

      {:ok, state} ->
        {:error,
         Error.new(:validation, "VALIDATION_FAILED", Enum.join(state.summaries, "\n"),
           details: state.details
         )}

      {:error, _error} = error ->
        error
    end
  end

  defp continue({:ok, _state} = ok), do: {:cont, ok}
  defp continue({:error, _error} = error), do: {:halt, error}

  defp visit(component, list, path, state) when is_list(list) do
    list
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, state}, fn {item, index}, {:ok, state} ->
      continue(visit(component, item, "#{path}.#{index}", state))
    end)
  end

  defp visit(component, %{} = node, path, state) do
    own =
      case node["@call"] do
        "@" <> _system -> {:ok, state}
        name when is_binary(name) -> check_call(component, name, node, path, state)
        _other -> {:ok, state}
      end

    with {:ok, state} <- own do
      node
      |> Enum.sort_by(&elem(&1, 0))
      |> Enum.reduce_while({:ok, state}, fn {key, value}, {:ok, state} ->
        continue(visit(component, value, "#{path}.#{key}", state))
      end)
    end
  end

  defp visit(_component, _value, _path, state), do: {:ok, state}

  defp check_call(component, name, call, path, state) do
    location = "components.#{component.id}.#{path}"
    catalog_id = call["catalogId"]

    if not is_nil(catalog_id) and not is_binary(catalog_id),
      do: non_string_catalog(component, name, location, state),
      else: resolve_and_check(component, name, call, location, catalog_id, state)
  end

  # Component validation reports a non-string `catalogId` when there is a
  # configuration.
  defp non_string_catalog(_component, _name, _location, %{config: %Config{}} = state),
    do: {:ok, state}

  defp non_string_catalog(component, name, location, state) do
    detail = Detail.new("type_mismatch", "'catalogId' must be a string", location <> ".catalogId")

    summary =
      "Function call '#{name}' in component '#{component.id}' has a non-string 'catalogId'."

    {:ok, %{state | details: state.details ++ [detail], summaries: state.summaries ++ [summary]}}
  end

  defp resolve_and_check(component, name, call, location, catalog_id, state) do
    subject = "Function call '#{name}' in component '#{component.id}'"

    case Surface.resolve_catalog(state.surface, catalog_id, subject) do
      {:ok, catalog} -> check_arguments(component, name, call, location, catalog, state)
      {:error, error} -> {:error, unavailable(catalog_id, state) || error}
    end
  end

  # A catalog the processor holds that the surface cannot use, because
  # its protocol version differs.
  defp unavailable(nil, _state), do: nil

  defp unavailable(catalog_id, state) do
    if Enum.any?(state.catalogs, &(&1.catalog_id == catalog_id)) do
      version = Surface.protocol_version(state.surface) || ""

      Error.new(
        :catalog,
        "CATALOG_ERROR",
        "Catalog '#{catalog_id}' is not available on surface #{state.surface.id}: its " <>
          "protocol version does not match the surface (#{label(version)})."
      )
    end
  end

  defp check_arguments(_component, _name, _call, _location, _catalog, %{config: nil} = state),
    do: {:ok, state}

  defp check_arguments(component, name, call, location, catalog, state) do
    if runs_in_component_catalog?(call["catalogId"], component, state.surface) do
      {:ok, state}
    else
      case Payload.validate_function(catalog, name, call["args"], state.config) do
        {:ok, _args} ->
          {:ok, state}

        {:error, %Error{} = error} ->
          summary =
            "Validation failed for function call '#{name}' in component '#{component.id}': " <>
              error.message

          {:ok,
           %{
             state
             | details: state.details ++ Payload.rebase({:error, error}, name, location),
               summaries: state.summaries ++ [summary]
           }}
      end
    end
  end

  # A call runs in the catalog it names, or else in the surface default; a
  # call that names none runs in its component's catalog only when that
  # catalog is the default.
  defp runs_in_component_catalog?(nil, component, surface),
    do: surface.catalog_id != nil and component.catalog_id == surface.catalog_id

  defp runs_in_component_catalog?(catalog_id, component, _surface),
    do: catalog_id == component.catalog_id

  @doc """
  Combines the errors of the nested-call pass (`first`) and of component
  validation (`second`), keeping a detail both report once.
  """
  @spec merge(Error.t(), Error.t()) :: Error.t()
  def merge(%Error{} = first, %Error{} = second) do
    first_count = length(first.details)

    {details, added, _seen} =
      (first.details ++ second.details)
      |> Enum.with_index()
      |> Enum.reduce({[], [], MapSet.new()}, fn {detail, index}, {details, added, seen} ->
        key = {detail.path, detail.code, detail.message}

        cond do
          MapSet.member?(seen, key) -> {details, added, seen}
          index >= first_count -> {[detail | details], [detail | added], MapSet.put(seen, key)}
          true -> {[detail | details], added, MapSet.put(seen, key)}
        end
      end)

    added = Enum.reverse(added)

    message =
      cond do
        length(added) == length(second.details) ->
          first.message <> "\n" <> second.message

        added != [] ->
          first.message <>
            "\nValidation failed for component:\n" <>
            Enum.map_join(added, "\n", &"#{&1.path}: #{&1.message}")

        true ->
          first.message
      end

    %{first | message: message, details: Enum.reverse(details)}
  end

  @doc """
  A protocol version as a `vX.Y` label, or as given when it is not one.
  """
  @spec label(String.t()) :: String.t()
  def label(version) do
    case Version.to_protocol_version(version) do
      {:ok, canonical} -> canonical
      :error -> version
    end
  end
end

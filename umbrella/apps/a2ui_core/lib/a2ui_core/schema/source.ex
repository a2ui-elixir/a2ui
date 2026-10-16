defmodule A2UICore.Schema.Source do
  @moduledoc """
  Loads the A2UI protocol's own JSON Schema documents — vendored under
  `priv/` from a pinned revision of the specification — plus the shipped
  basic catalogs.

  Documents are read once and cached in `:persistent_term` (they are
  immutable, process-free data). The vendored copies are the single
  source of truth for envelope validation.

  ## Layout

      priv/schemas/v0_9/*.json       v0.9 wire schemas (server_to_client, …)
      priv/schemas/v0_9_1/*.json     v0.9.1 wire schemas
      priv/schemas/v1_0/*.json       v1.0 wire schemas (agent_to_renderer, …)
      priv/catalogs/basic_v0_9_1.json    basic catalog, protocol version 0.9
      priv/catalogs/basic_v1_0.json      basic catalog, protocol version 1.0
      priv/catalogs/testing_v1_0.json    upstream `testing_catalog.json`
  """

  alias A2UICore.Version

  @moduledoc since: "0.1.0"

  @type document :: A2UICore.Schema.schema()

  @doc """
  Returns the priv directory holding the vendored documents.
  """
  @spec priv_dir() :: Path.t()
  def priv_dir, do: Application.app_dir(:a2ui_core, "priv")

  @doc """
  Loads a wire-schema document by version and logical name.

  Logical names normalize the v0.9/v1.0 file renames:

      :agent_to_renderer   v0.9.x -> server_to_client.json
                          v1.0   -> agent_to_renderer.json
      :renderer_to_agent   v0.9.x -> client_to_server.json
                          v1.0   -> renderer_to_agent.json
      :common_types        common_types.json
      :capabilities        v0.9.x -> server_capabilities.json (agent side)
                          v1.0   -> agent_capabilities.json
      :renderer_capabilities  v0.9.x -> client_capabilities.json
                              v1.0   -> renderer_capabilities.json
      :data_model          v0.9.x -> client_data_model.json
                          v1.0   -> renderer_data_model.json
      :list                v0.9.x -> server_to_client_list.json
                          v1.0   -> agent_to_renderer_list.json
      :wrapper             v0.9.x -> server_to_client_list_wrapper.json
                          v1.0   -> agent_to_renderer_list_wrapper.json
      :catalog_definition  v1.0   -> catalog_definition.json (nil for v0.9.x)

  Any concrete file name (e.g. `"sample.json"`) is loaded verbatim.
  """
  @spec document(Version.protocol_version() | String.t(), atom() | String.t()) ::
          document() | nil
  def document(version, name) do
    case resolve_file(version, name) do
      {:ok, file} -> load_cached("schemas/#{schema_dir(version)}/#{file}")
      :error -> nil
    end
  end

  @doc """
  Like `document/2`, decoded with its key order (`Jason.OrderedObject`s),
  for writing the document out in the order it is published in.
  """
  @spec ordered_document(Version.protocol_version() | String.t(), atom() | String.t()) ::
          Jason.OrderedObject.t() | nil
  def ordered_document(version, name) do
    case resolve_file(version, name) do
      {:ok, file} -> load_cached("schemas/#{schema_dir(version)}/#{file}", :ordered)
      :error -> nil
    end
  end

  @doc """
  Loads a shipped catalog by protocol version.

      :basic      the basic catalog for the given protocol line
      :testing    the upstream spec-test catalog (v1.0 only)
  """
  @spec catalog(Version.protocol_version() | String.t(), :basic | :testing) ::
          document() | nil
  def catalog(version, kind), do: load_cached(catalog_file(version, kind))

  @doc """
  Like `catalog/2`, decoded with its key order (`Jason.OrderedObject`s),
  which orders the components and functions of a catalog built from it
  (`A2UICore.Catalog.from_json/2`). Not cached.
  """
  @spec ordered_catalog(Version.protocol_version() | String.t(), :basic | :testing) ::
          Jason.OrderedObject.t() | nil
  def ordered_catalog(version, kind) do
    case File.read(Path.join(priv_dir(), catalog_file(version, kind))) do
      {:ok, contents} -> Jason.decode!(contents, objects: :ordered_objects)
      {:error, _reason} -> nil
    end
  end

  defp catalog_file("v0.9", :basic), do: "catalogs/basic_v0_9_1.json"
  defp catalog_file("v0.9.1", :basic), do: "catalogs/basic_v0_9_1.json"
  defp catalog_file("v1.0", :basic), do: "catalogs/basic_v1_0.json"
  defp catalog_file("v1.0", :testing), do: "catalogs/testing_v1_0.json"

  defp catalog_file(_version, :testing),
    do: raise(ArgumentError, "testing catalog exists only for v1.0")

  defp catalog_file(version, _kind) do
    raise ArgumentError,
          "no catalog for protocol version #{inspect(version)}; supported: v0.9, v0.9.1, v1.0"
  end

  defp schema_dir("v0.9"), do: "v0_9"
  defp schema_dir("v0.9.1"), do: "v0_9_1"
  defp schema_dir("v1.0"), do: "v1_0"

  defp resolve_file("v0.9" = v, name), do: resolve_file(v, name, :v0_9)
  defp resolve_file("v0.9.1" = v, name), do: resolve_file(v, name, :v0_9)
  defp resolve_file("v1.0" = v, name), do: resolve_file(v, name, :v1_0)

  defp resolve_file(version, _name),
    do: raise(ArgumentError, "unknown protocol version #{inspect(version)}")

  defp resolve_file(_version, name, line) when is_atom(name) do
    case file_for(name, line) do
      nil -> :error
      file -> {:ok, file}
    end
  end

  defp resolve_file(_version, name, _line) when is_binary(name), do: {:ok, name}

  defp file_for(:agent_to_renderer, :v0_9), do: "server_to_client.json"
  defp file_for(:renderer_to_agent, :v0_9), do: "client_to_server.json"
  defp file_for(:common_types, :v0_9), do: "common_types.json"
  defp file_for(:capabilities, :v0_9), do: "server_capabilities.json"
  defp file_for(:renderer_capabilities, :v0_9), do: "client_capabilities.json"
  defp file_for(:data_model, :v0_9), do: "client_data_model.json"
  defp file_for(:list, :v0_9), do: "server_to_client_list.json"
  defp file_for(:wrapper, :v0_9), do: "server_to_client_list_wrapper.json"
  # v0.9 has no catalog meta-schema.
  defp file_for(:catalog_definition, :v0_9), do: nil

  defp file_for(:agent_to_renderer, :v1_0), do: "agent_to_renderer.json"
  defp file_for(:renderer_to_agent, :v1_0), do: "renderer_to_agent.json"
  defp file_for(:common_types, :v1_0), do: "common_types.json"
  defp file_for(:capabilities, :v1_0), do: "agent_capabilities.json"
  defp file_for(:renderer_capabilities, :v1_0), do: "renderer_capabilities.json"
  defp file_for(:data_model, :v1_0), do: "renderer_data_model.json"
  defp file_for(:list, :v1_0), do: "agent_to_renderer_list.json"
  defp file_for(:wrapper, :v1_0), do: "agent_to_renderer_list_wrapper.json"
  defp file_for(:catalog_definition, :v1_0), do: "catalog_definition.json"

  defp file_for(other, _line) when is_atom(other), do: to_string(other) <> ".json"

  # read-through cache --------------------------------------------------------

  @spec load_cached(String.t(), :plain | :ordered) :: document() | Jason.OrderedObject.t() | nil
  defp load_cached(rel, mode \\ :plain) do
    key = {__MODULE__, mode, rel}

    case :persistent_term.get(key, :missing) do
      :missing ->
        doc = read_document(Path.join(priv_dir(), rel), mode)
        :persistent_term.put(key, doc)
        doc

      doc ->
        doc
    end
  end

  defp read_document(path, mode) do
    case File.read(path) do
      {:ok, contents} when mode == :ordered -> Jason.decode!(contents, objects: :ordered_objects)
      {:ok, contents} -> Jason.decode!(contents)
      {:error, _reason} -> nil
    end
  end
end

defmodule A2UICore.State.Surface do
  @moduledoc """
  The state of one UI surface: its identity, catalog selection, theme,
  data model and components.

  A surface is plain data. Mutating operations return the updated
  surface (and, where something observable happened, effects); nothing
  is delivered by callback. The processor (`A2UICore.Processor`) is what
  applies protocol messages to surfaces.

    * `:id` — the surface id, unique within a group.
    * `:catalog_id` — the default catalog's id (`nil` until resolved).
    * `:catalogs` — `%{catalog_id => catalog}` available to the surface.
    * `:theme` — theme properties (v0.9; empty under v1.0).
    * `:send_data_model` — whether the renderer should attach this
      surface's data model to outbound action messages.
    * `:root_id` — the entry component, `"root"` by default.
    * `:data_model` — an `A2UICore.State.DataModel`.
    * `:components` — an `A2UICore.State.Components`.
    * `:version` — the protocol version the surface was created under.
    * `:metadata` — free-form host data, never sent on the wire.
  """

  alias A2UICore.State.{Components, DataModel}

  @moduledoc since: "0.1.0"

  @enforce_keys [:id]
  defstruct [
    :id,
    :catalog_id,
    :version,
    catalogs: %{},
    theme: %{},
    send_data_model: false,
    root_id: "root",
    data_model: nil,
    components: nil,
    metadata: %{}
  ]

  @type t :: %__MODULE__{
          id: String.t(),
          catalog_id: String.t() | nil,
          version: String.t() | nil,
          catalogs: %{optional(String.t()) => term()},
          theme: map(),
          send_data_model: boolean(),
          root_id: String.t(),
          data_model: DataModel.t(),
          components: Components.t(),
          metadata: map()
        }

  @doc """
  Creates a surface. Options: `:catalog_id`, `:catalogs`, `:theme`,
  `:send_data_model`, `:root_id`, `:data_model` (a model or initial
  data), `:version`, `:metadata`.

      iex> surface = A2UICore.State.Surface.new("main", send_data_model: true)
      iex> {surface.id, surface.root_id, surface.send_data_model}
      {"main", "root", true}
  """
  @spec new(String.t(), keyword()) :: t()
  def new(id, options \\ []) when is_binary(id) do
    data_model =
      case Keyword.get(options, :data_model) do
        %DataModel{} = model -> model
        initial -> DataModel.new(initial)
      end

    %__MODULE__{
      id: id,
      catalog_id: options[:catalog_id],
      version: options[:version],
      catalogs: Keyword.get(options, :catalogs, %{}),
      theme: options[:theme] || %{},
      send_data_model: Keyword.get(options, :send_data_model, false),
      root_id: Keyword.get(options, :root_id, "root"),
      data_model: data_model,
      components: Components.new(),
      metadata: Keyword.get(options, :metadata, %{})
    }
  end

  @doc """
  The surface's default catalog, or `nil` when it has none.
  """
  @spec default_catalog(t()) :: A2UICore.Catalog.t() | nil
  def default_catalog(%__MODULE__{catalog_id: catalog_id, catalogs: catalogs}),
    do: Map.get(catalogs, catalog_id)

  @doc """
  Writes into the surface's data model; see `A2UICore.State.DataModel.set/3`.
  """
  @spec set_data(t(), term(), term()) ::
          {:ok, t(), [DataModel.notification()]} | {:error, A2UICore.Error.t()}
  def set_data(%__MODULE__{} = surface, path, value) do
    with {:ok, model, notifications} <- DataModel.set(surface.data_model, path, value) do
      {:ok, %{surface | data_model: model}, notifications}
    end
  end

  @doc """
  Reads from the surface's data model; see `A2UICore.State.DataModel.get/2`.
  """
  @spec get_data(t(), term()) :: {:ok, term()} | {:error, A2UICore.Error.t()}
  def get_data(%__MODULE__{data_model: model}, path), do: DataModel.get(model, path)

  @doc """
  Replaces the surface's components.
  """
  @spec put_components(t(), Components.t()) :: t()
  def put_components(%__MODULE__{} = surface, %Components{} = components),
    do: %{surface | components: components}

  @doc """
  Builds the action event a component interaction produces, or `nil`
  when `payload` is not an action.

  `payload` is either an action object (`%{"name" => …, "context" => …}`)
  or `%{"event" => %{…}}`, optionally carrying a `"catalogId"`. The
  event has `name`, `surfaceId`, `sourceComponentId`, `timestamp`
  (RFC 3339, UTC), `context` (empty when absent or not an object) and,
  when present, `catalogId` and `userMessage`.

  `now` is the event time; it defaults to the current UTC time and is
  a parameter so callers and tests can keep the core deterministic.

      iex> surface = A2UICore.State.Surface.new("main")
      iex> now = ~U[2026-01-02 03:04:05Z]
      iex> A2UICore.State.Surface.dispatch_action(surface, %{"name" => "save"}, "btn", now)
      %{
        "name" => "save",
        "surfaceId" => "main",
        "sourceComponentId" => "btn",
        "timestamp" => "2026-01-02T03:04:05Z",
        "context" => %{}
      }
  """
  @spec dispatch_action(t(), term(), String.t(), DateTime.t()) :: map() | nil
  def dispatch_action(surface, payload, source_component_id, now \\ DateTime.utc_now())

  def dispatch_action(%__MODULE__{} = surface, payload, source_component_id, now)
      when is_map(payload) do
    with {:ok, event} <- event_payload(payload),
         name when is_binary(name) and name != "" <- event["name"] do
      %{
        "name" => name,
        "surfaceId" => surface.id,
        "sourceComponentId" => source_component_id,
        "timestamp" => timestamp(now),
        "context" => if(is_map(event["context"]), do: event["context"], else: %{})
      }
      |> put_string("catalogId", payload["catalogId"] || event["catalogId"])
      |> put_string("userMessage", event["userMessage"])
    else
      _ -> nil
    end
  end

  def dispatch_action(%__MODULE__{}, _payload, _source_component_id, _now), do: nil

  defp event_payload(%{"event" => event}) when is_map(event), do: {:ok, event}
  defp event_payload(%{"name" => _} = payload), do: {:ok, payload}
  defp event_payload(_payload), do: :error

  defp put_string(map, key, value) when is_binary(value) and value != "",
    do: Map.put(map, key, value)

  defp put_string(map, _key, _value), do: map

  # RFC 3339 UTC; fractional seconds only when there are any.
  defp timestamp(%DateTime{microsecond: {0, _}} = now),
    do:
      now
      |> DateTime.shift_zone!("Etc/UTC")
      |> DateTime.truncate(:second)
      |> DateTime.to_iso8601()

  defp timestamp(%DateTime{} = now),
    do: now |> DateTime.shift_zone!("Etc/UTC") |> DateTime.to_iso8601()

  @doc """
  Releases the surface's resources: detaches data-model subscriptions.
  """
  @spec dispose(t()) :: t()
  def dispose(%__MODULE__{data_model: model} = surface),
    do: %{surface | data_model: DataModel.dispose(model)}
end

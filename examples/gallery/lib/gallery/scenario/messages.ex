defmodule Gallery.Scenario.Messages do
  @moduledoc """
  Shorthands for the messages scenarios send. They produce plain A2UI
  messages, so a scenario still reads like what goes over the wire.
  """

  @basic "https://a2ui.org/specification/v1_0/catalogs/basic/catalog.json"

  @doc """
  A v1.0 `createSurface`. Options: `:catalog_id` (default: the basic
  catalog), `:components`, `:data` (the initial data model),
  `:send_data_model`.
  """
  def create(surface_id, options \\ []) do
    body =
      %{"surfaceId" => surface_id, "catalogId" => Keyword.get(options, :catalog_id, @basic)}
      |> put_present("components", options[:components])
      |> put_present("dataModel", options[:data])
      |> put_present("sendDataModel", options[:send_data_model])

    %{"version" => "v1.0", "createSurface" => body}
  end

  @doc "A v1.0 `updateComponents`."
  def components(surface_id, components),
    do: %{
      "version" => "v1.0",
      "updateComponents" => %{"surfaceId" => surface_id, "components" => components}
    }

  @doc """
  A v1.0 `updateDataModel`. Without a value it deletes the path: v1.0
  requires `value`, and `null` removes the key.
  """
  def data(surface_id, path, value \\ nil) do
    %{
      "version" => "v1.0",
      "updateDataModel" => %{"surfaceId" => surface_id, "path" => path, "value" => value}
    }
  end

  @doc "A v1.0 `deleteSurface`."
  def delete(surface_id),
    do: %{"version" => "v1.0", "deleteSurface" => %{"surfaceId" => surface_id}}

  @doc "A binding to `path`."
  def path(path), do: %{"@path" => path}

  @doc "A call of `name` with `args`."
  def call(name, args \\ %{}), do: %{"@call" => name, "args" => args}

  @doc "An event action."
  def event(name, context \\ %{}), do: %{"event" => %{"name" => name, "context" => context}}

  @doc "A Text component."
  def text(id, text, extra \\ %{}),
    do: Map.merge(%{"id" => id, "component" => "Text", "text" => text}, extra)

  @doc "A Button with a Text label (two components)."
  def button(id, label, action, extra \\ %{}) do
    [
      Map.merge(
        %{"id" => id, "component" => "Button", "child" => id <> "_label", "action" => action},
        extra
      ),
      text(id <> "_label", label)
    ]
  end

  @doc "The kind of a message: its key other than `version`."
  def kind(%{} = message), do: message |> Map.delete("version") |> Map.keys() |> List.first()

  defp put_present(map, _key, nil), do: map
  defp put_present(map, key, value), do: Map.put(map, key, value)
end

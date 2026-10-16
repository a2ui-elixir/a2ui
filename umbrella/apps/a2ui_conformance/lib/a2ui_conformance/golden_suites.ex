defmodule A2UIConformance.GoldenSuites do
  @moduledoc false

  # What the builder and macro suites share (the reference's
  # builder_suite.py and macro_suite.py): the builder AST of a case, its
  # golden file, and the check that a golden payload passes a renderer's
  # validation with the relaxations the case declares.

  import ExUnit.Assertions

  alias A2UIAgent.Builder
  alias A2UIConformance.Registry
  alias A2UICore.{Catalog, Processor}
  alias A2UICore.Validation.Config

  @doc false
  # The golden file `name` of the suite `suite` (a path under
  # `conformance/`).
  @spec golden(String.t(), String.t()) :: term()
  def golden(suite, name) do
    [Registry.reference_root(), "conformance", Path.dirname(suite), "golden", name]
    |> Path.join()
    |> File.read!()
    |> Jason.decode!()
  end

  @doc false
  # Builds the tree a builder AST declares. Sentinel keys name the
  # constructs JSON has no spelling for; anything else is matched on its
  # discriminating field (`call`, then `component`).
  @spec ast(term()) :: term()
  def ast(list) when is_list(list), do: Enum.map(list, &ast/1)
  def ast(%{"$bind" => path}), do: Builder.bind(path)
  def ast(%{"$componentRef" => id}), do: Builder.ref(id)

  def ast(%{"$dynamicChildList" => spec}),
    do: Builder.child_list(spec["path"], ast(spec["template"]))

  def ast(%{"$checkRule" => spec}), do: Builder.check(ast(spec["condition"]), spec["message"])
  def ast(%{"$accessibility" => attributes}), do: Builder.accessibility(values(attributes))
  def ast(%{"$action" => spec}), do: action(spec)

  def ast(%{"$tabItem" => spec}),
    do: %{"title" => ast(spec["title"]), "child" => ast(spec["child"])}

  def ast(%{"$choiceOption" => spec}),
    do: %{"label" => ast(spec["label"]), "value" => spec["value"]}

  def ast(%{"call" => name} = call), do: Builder.call(name, values(call["args"] || %{}))

  def ast(%{"component" => name} = node),
    do: Builder.component(name, node |> Map.delete("component") |> values())

  def ast(%{} = map), do: values(map)
  def ast(value), do: value

  defp values(map), do: Map.new(map, fn {key, value} -> {key, ast(value)} end)

  defp action(%{"event" => name}) when is_binary(name), do: Builder.event(name)

  defp action(%{"event" => event}),
    do: Builder.event(event["name"], event["context"] && values(event["context"]))

  defp action(%{"functionCall" => call}), do: Builder.action(ast(call))

  @doc false
  # Processes `payload` as a renderer holding `catalogs` would, with the
  # case's `validation` relaxations. A payload that creates no surface
  # updates one that exists already, with the first catalog.
  @spec assert_valid([map()], map(), [Catalog.t()]) :: true
  def assert_valid(payload, raw, [default | _] = catalogs) do
    relaxations = raw["validation"] || %{}

    config = %{
      Config.strict()
      | allow_missing_root: relaxations["allow_missing_root"] == true,
        allow_orphan_components: relaxations["allow_orphan_components"] == true,
        allow_dangling_references: relaxations["allow_dangling_references"] == true
    }

    payload =
      if Enum.any?(payload, &Map.has_key?(&1, "createSurface")) do
        payload
      else
        create = %{"surfaceId" => raw["surface_id"], "catalogId" => default.catalog_id}
        [%{"version" => hd(payload)["version"], "createSurface" => create} | payload]
      end

    processor = Processor.new(catalogs, validation: config)

    case Processor.process(processor, payload) do
      {:ok, _processor, _effects} ->
        true

      {:error, error, _processor} ->
        flunk("golden payload is invalid: #{Exception.message(error)}")
    end
  end
end

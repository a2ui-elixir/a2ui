defmodule A2UIConformance.Handlers.DataModel do
  @moduledoc false

  # `data_model` (reference harness L1248-1344): builds a model from
  # `initial`, attaches an observer to every `watch` path, then runs
  # `steps` in order.
  #
  # Step ops: `get` (asserting `expect`, `expect_absent`, `expect_type`),
  # `set`, `delete`, `dispose`. A step carrying `expect_error` /
  # `expectError` must fail with a matching error and skips the
  # notification checks. Otherwise `expect_notified` is compared as a
  # multiset of watch strings (one entry per observer that fired) and
  # `expect_values` reads the *first* observer registered for that raw
  # path (its last notified value, or its initial value). A case-level
  # `expect` is compared against the whole model at the end.

  @behaviour A2UIConformance.Handler

  import ExUnit.Assertions

  alias A2UIConformance.{Case, Matchers}
  alias A2UICore.State.DataModel

  @impl true
  def run(%Case{raw: raw}, _context) do
    model = DataModel.new(raw["initial"])

    {model, observers} =
      Enum.reduce(raw["watch"] || [], {model, []}, fn path, {model, observers} ->
        {:ok, model, id, initial} = DataModel.subscribe(model, path)
        {model, observers ++ [%{id: id, path: path, value: initial}]}
      end)

    state = %{model: model, observers: observers}

    final =
      raw["steps"]
      |> List.wrap()
      |> Enum.with_index()
      |> Enum.reduce(state, fn {step, index}, state -> run_step(step, index, state) end)

    if Map.has_key?(raw, "expect") do
      Matchers.assert_json_equal(raw["expect"], DataModel.get!(final.model, "/"), "final model")
    end

    :ok
  end

  defp run_step(step, index, state) do
    expect_error = step["expect_error"] || step["expectError"]

    case {apply_op(step, state), expect_error} do
      {{:error, error}, nil} ->
        flunk("step #{index} (#{step["op"]}): unexpected error #{Exception.message(error)}")

      {{:error, error}, expected} ->
        Matchers.assert_error(expected, error)
        state

      {{:ok, _result, _state}, expected} when expected != nil ->
        flunk("step #{index} (#{step["op"]}): expected an error, got success")

      {{:ok, notifications, state}, nil} ->
        state = apply_notifications(state, notifications)
        assert_notified(step, index, notifications, state)
        assert_values(step, index, state)
        state
    end
  end

  defp apply_op(%{"op" => "get"} = step, state) do
    with {:ok, actual} <- DataModel.get(state.model, step["path"] || "") do
      if step["expect_absent"] == true do
        assert is_nil(actual), "expected '#{step["path"]}' to be absent, got #{inspect(actual)}"
      end

      assert_type(step["expect_type"], actual, step["path"])

      if Map.has_key?(step, "expect") do
        Matchers.assert_json_equal(step["expect"], actual, "get '#{step["path"]}'")
      end

      {:ok, [], state}
    end
  end

  defp apply_op(%{"op" => "set"} = step, state),
    do: write(state, step["path"] || "", step["value"])

  defp apply_op(%{"op" => "delete"} = step, state), do: write(state, step["path"] || "", nil)

  defp apply_op(%{"op" => "dispose"}, state),
    do: {:ok, [], %{state | model: DataModel.dispose(state.model)}}

  defp apply_op(%{"op" => op}, _state), do: raise(ArgumentError, "unknown data_model op: #{op}")

  defp write(state, path, value) do
    with {:ok, model, notifications} <- DataModel.set(state.model, path, value) do
      {:ok, notifications, %{state | model: model}}
    end
  end

  defp assert_type(nil, _actual, _path), do: :ok
  defp assert_type("list", actual, path), do: assert(is_list(actual), "'#{path}' is not a list")

  defp assert_type("object", actual, path),
    do: assert(is_map(actual), "'#{path}' is not an object")

  # Observers remember the last value they were notified with.
  defp apply_notifications(state, notifications) do
    observers =
      Enum.map(state.observers, fn observer ->
        case List.keyfind(notifications, observer.id, 0) do
          {_id, _path, value} -> %{observer | value: value}
          nil -> observer
        end
      end)

    %{state | observers: observers}
  end

  defp assert_notified(step, index, notifications, state) do
    if Map.has_key?(step, "expect_notified") do
      fired = for {id, _path, _value} <- notifications, do: observer_path(state, id)

      assert Enum.sort(fired) == Enum.sort(step["expect_notified"]),
             "step #{index} (#{step["op"]}) expect_notified mismatch: " <>
               "got #{inspect(fired)}, expected #{inspect(step["expect_notified"])}"
    end
  end

  defp assert_values(step, index, state) do
    for {path, expected} <- step["expect_values"] || %{} do
      observer = Enum.find(state.observers, &(&1.path == path))
      assert observer, "path '#{path}' in expect_values is not watched"

      Matchers.assert_json_equal(
        expected,
        observer.value,
        "step #{index} (#{step["op"]}) expect_values for '#{path}'"
      )
    end
  end

  defp observer_path(state, id), do: Enum.find(state.observers, &(&1.id == id)).path
end

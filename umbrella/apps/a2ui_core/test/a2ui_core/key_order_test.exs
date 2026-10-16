defmodule A2UICore.KeyOrderTest do
  @moduledoc false
  use ExUnit.Case, async: true

  doctest A2UICore.KeyOrder

  alias A2UICore.KeyOrder

  defp ordered(json), do: Jason.decode!(json, objects: :ordered_objects)

  test "like/2 follows the template item by item, or item by equal item" do
    template = ordered(~s([{"b": 1, "a": 2}, {"d": 1, "c": 2}]))

    assert [%{"a" => 1, "b" => 2}, %{"c" => 1, "d" => 2}]
           |> KeyOrder.like(template)
           |> Jason.encode!() == ~s([{"b":2,"a":1},{"d":2,"c":1}])

    template = ordered(~s([{"y": 1, "x": 2}, {"q": [1], "p": 2}]))

    assert [%{"p" => 2, "q" => [1]}]
           |> KeyOrder.like(template)
           |> Jason.encode!() == ~s([{"q":[1],"p":2}])

    assert KeyOrder.like([%{"b" => 1, "a" => 2}], nil) |> Jason.encode!() == ~s([{"a":2,"b":1}])

    kept = KeyOrder.new([{"z", 1}, {"a", 2}])
    assert KeyOrder.like(kept, ordered(~s({"a": 1, "z": 2}))) == kept
    assert KeyOrder.like(3, nil) == 3
  end

  test "reading ordered objects and maps alike" do
    object = KeyOrder.new([{"a", 1}])

    assert KeyOrder.get(object, "a") == 1
    assert KeyOrder.get(object, "b") == nil
    assert KeyOrder.get(%{"a" => 1}, "a") == 1
    assert KeyOrder.get(nil, "a") == nil

    assert KeyOrder.has_key?(object, "a")
    assert KeyOrder.has_key?(%{"a" => nil}, "a")
    refute KeyOrder.has_key?(object, "b")
    refute KeyOrder.has_key?([], "a")

    assert KeyOrder.empty?(KeyOrder.new())
    assert KeyOrder.empty?(%{})
    refute KeyOrder.empty?(object)
  end

  test "put/3 replaces in place and appends new keys; put_new/3 and delete/2" do
    object = KeyOrder.new([{"a", 1}, {"b", 2}])

    assert KeyOrder.put(object, "a", 3).values == [{"a", 3}, {"b", 2}]
    assert KeyOrder.put(object, "c", 3).values == [{"a", 1}, {"b", 2}, {"c", 3}]
    assert KeyOrder.put_new(object, "a", 9) == object
    assert KeyOrder.put_new(object, "c", 9).values == [{"a", 1}, {"b", 2}, {"c", 9}]
    assert KeyOrder.delete(object, "a").values == [{"b", 2}]
  end

  test "put/3 and delete/2 update maps as maps" do
    assert KeyOrder.put(%{"a" => 1}, "b", 2) == %{"a" => 1, "b" => 2}
    assert KeyOrder.delete(%{"a" => 1, "b" => 2}, "a") == %{"b" => 2}
  end

  test "message/1 writes a message in the protocol's order" do
    message = %{
      "version" => "v1.0",
      "createSurface" => %{
        "sendDataModel" => true,
        "dataModel" => %{"b" => 1, "a" => 2},
        "components" => [
          %{"text" => "Hi", "component" => "Text", "id" => "root", "accessibility" => %{}}
        ],
        "catalogId" => "c",
        "surfaceId" => "s",
        "extra" => 1
      }
    }

    assert message |> KeyOrder.message() |> Jason.encode!() ==
             ~s({"version":"v1.0","createSurface":{"surfaceId":"s","catalogId":"c","sendDataModel":true,) <>
               ~s("components":[{"id":"root","component":"Text","accessibility":{},"text":"Hi"}],) <>
               ~s("dataModel":{"a":2,"b":1},"extra":1}})

    assert %{"updateDataModel" => %{"value" => nil, "path" => "/x", "surfaceId" => "s"}}
           |> KeyOrder.message()
           |> Jason.encode!() ==
             ~s({"updateDataModel":{"surfaceId":"s","path":"/x","value":null}})

    ordered = KeyOrder.new([{"b", 1}, {"a", 2}])
    assert KeyOrder.message(ordered) == ordered
    assert KeyOrder.message(42) == 42
    assert KeyOrder.message(%{"custom" => [1]}) |> Jason.encode!() == ~s({"custom":[1]})
  end

  test "to_plain/1 turns ordered objects into maps, recursively" do
    assert KeyOrder.to_plain(ordered(~s({"a": [{"b": 1}], "c": {"d": null}}))) ==
             %{"a" => [%{"b" => 1}], "c" => %{"d" => nil}}

    assert KeyOrder.to_plain(%{"x" => KeyOrder.new([{"y", 1}])}) == %{"x" => %{"y" => 1}}
  end
end

defmodule A2UICore.State.DataModelTest do
  @moduledoc false
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias A2UICore.Error
  alias A2UICore.Pointer
  alias A2UICore.State.DataModel

  doctest A2UICore.State.DataModel

  defp set!(model, path, value) do
    assert {:ok, model, notifications} = DataModel.set(model, path, value)
    {model, notifications}
  end

  defp data_of(initial, path, value) do
    {model, _} = set!(DataModel.new(initial), path, value)
    DataModel.data(model)
  end

  defp error!(result) do
    assert {:error, %Error{category: :data} = error} = result
    error
  end

  describe "reads" do
    test "an absent path is nil; the root is the whole value" do
      model = DataModel.new(%{"a" => %{"b" => 1}})

      assert DataModel.get(model, "/a/b") == {:ok, 1}
      assert DataModel.get(model, "/a/missing") == {:ok, nil}
      assert DataModel.get(model, "/") == {:ok, %{"a" => %{"b" => 1}}}
      assert DataModel.get(model, "") == {:ok, %{"a" => %{"b" => 1}}}
    end

    test "new(nil) is an empty object" do
      assert DataModel.data(DataModel.new()) == %{}
      assert DataModel.data(DataModel.new(nil)) == %{}
    end

    test "falsy roots are stored as given" do
      for root <- [0, false, ""] do
        assert DataModel.get(DataModel.new(root), "/") == {:ok, root}
      end
    end

    test "has_path? tells an explicit null from a missing key" do
      model = DataModel.new(%{"a" => nil, "list" => [nil]})

      assert DataModel.has_path?(model, "/a") == {:ok, true}
      assert DataModel.has_path?(model, "/b") == {:ok, false}
      assert DataModel.has_path?(model, "/list/0") == {:ok, true}
      assert DataModel.has_path?(model, "/list/1") == {:ok, false}
      assert DataModel.has_path?(model, "/") == {:ok, true}
      assert DataModel.get(model, "/a") == {:ok, nil}
    end

    test "list elements address by RFC 6901 index; leading zeros are not indices" do
      model = DataModel.new(%{"items" => ["a", "b"]})

      assert DataModel.get(model, "/items/1") == {:ok, "b"}
      assert DataModel.get(model, "/items/01") == {:ok, nil}
      assert DataModel.get(model, "/items/2") == {:ok, nil}
      assert DataModel.get(model, "/items/-1") == {:ok, nil}
      assert DataModel.get(model, "/items/x") == {:ok, nil}
    end

    test "reading through a primitive is absent" do
      model = DataModel.new(%{"a" => 1})
      assert DataModel.get(model, "/a/b/c") == {:ok, nil}
      assert DataModel.has_path?(model, "/a/b") == {:ok, false}
    end

    test "escaped and collapsed segments" do
      model = DataModel.new(%{"a/b" => 1, "~" => 2, "x" => %{"y" => 3}})

      assert DataModel.get(model, "/a~1b") == {:ok, 1}
      assert DataModel.get(model, "/~0") == {:ok, 2}
      assert DataModel.get(model, "//x///y//") == {:ok, 3}
    end

    test "forbidden segments and non-string paths are data errors" do
      model = DataModel.new()

      for path <- ["/__proto__", "/a/constructor", "/prototype/x", 42, nil, :a] do
        error!(DataModel.get(model, path))
        error!(DataModel.has_path?(model, path))
        error!(DataModel.set(model, path, 1))
      end
    end

    test "get! raises the error" do
      assert DataModel.get!(DataModel.new(%{"a" => 1}), "/a") == 1
      assert_raise Error, fn -> DataModel.get!(DataModel.new(), "/__proto__") end
    end
  end

  describe "writes" do
    test "creates missing objects along the path" do
      assert data_of(%{}, "/a/b/c", 1) == %{"a" => %{"b" => %{"c" => 1}}}
    end

    test "a numeric next segment creates a list; \"01\" creates an object" do
      assert data_of(%{}, "/items/0/name", "x") == %{"items" => [%{"name" => "x"}]}
      assert data_of(%{}, "/a/01", 1) == %{"a" => %{"01" => 1}}
    end

    test "lists are padded with nil up to the written index" do
      assert data_of(%{"l" => ["a"]}, "/l/3", "x") == %{"l" => ["a", nil, nil, "x"]}
      assert data_of(%{}, "/l/2", 1) == %{"l" => [nil, nil, 1]}
    end

    test "the maximum array index is inclusive" do
      max = Pointer.max_array_index()
      {model, _} = set!(DataModel.new(), "/l/#{max}", 1)
      assert %{"l" => list} = DataModel.data(model)
      assert length(list) == max + 1

      error = error!(DataModel.set(DataModel.new(), "/l/#{max + 1}", 1))
      assert error.message =~ "array index '#{max + 1}' exceeds maximum supported index (#{max})"
    end

    test "falsy values are written, not treated as deletes" do
      for value <- [false, 0, ""] do
        {model, _} = set!(DataModel.new(), "/a", value)
        assert DataModel.get(model, "/a") == {:ok, value}
        assert DataModel.has_path?(model, "/a") == {:ok, true}
      end
    end

    test "writing through an explicit null replaces it with a container" do
      assert data_of(%{"a" => nil}, "/a/b", 1) == %{"a" => %{"b" => 1}}
      assert data_of(%{"l" => [nil]}, "/l/0/x", 1) == %{"l" => [%{"x" => 1}]}
      assert data_of(%{"a" => nil}, "/a/0", 1) == %{"a" => [1]}
    end

    test "overwrites replace the whole subtree" do
      assert data_of(%{"a" => %{"b" => 1}}, "/a", [1, 2]) == %{"a" => [1, 2]}
    end

    test "writing the root replaces the model" do
      assert data_of(%{"a" => 1}, "/", %{"b" => 2}) == %{"b" => 2}
      assert data_of(%{"a" => 1}, "", [1]) == [1]
    end

    test "writes into an existing list" do
      assert data_of(%{"l" => [%{"n" => 1}, %{"n" => 2}]}, "/l/1/n", 9) ==
               %{"l" => [%{"n" => 1}, %{"n" => 9}]}
    end
  end

  describe "deletes" do
    test "removes an object key" do
      assert data_of(%{"a" => 1, "b" => 2}, "/a", nil) == %{"b" => 2}
    end

    test "a list slot becomes nil and the list keeps its length" do
      assert data_of(%{"l" => [1, 2, 3]}, "/l/1", nil) == %{"l" => [1, nil, 3]}
    end

    test "deleting past the end of a list does not grow it" do
      assert data_of(%{"l" => [1]}, "/l/5", nil) == %{"l" => [1]}
    end

    test "deleting an absent path is a no-op with no notifications" do
      {:ok, model, _id, nil} = DataModel.subscribe(DataModel.new(%{"a" => 1}), "/x")
      {after_delete, notifications} = set!(model, "/x/y/z", nil)

      assert after_delete == model
      assert notifications == []
    end

    test "deleting through a primitive is a no-op, not an error" do
      assert data_of(%{"a" => 1}, "/a/b", nil) == %{"a" => 1}
    end

    test "a nil root write resets the model to an empty object" do
      assert data_of(%{"a" => 1}, "/", nil) == %{}
      assert data_of(5, "/", nil) == %{}
    end

    test "delete/2 is set(path, nil)" do
      model = DataModel.new(%{"a" => 1})
      assert {:ok, deleted, []} = DataModel.delete(model, "/a")
      assert DataModel.data(deleted) == %{}
    end
  end

  describe "write errors" do
    test "a primitive in the middle of the path" do
      error = error!(DataModel.set(DataModel.new(%{"a" => 1}), "/a/b", 2))
      assert error.message =~ "segment 'a' is a primitive value"
      assert error.path == "/a/b"
    end

    test "a primitive root cannot be written through" do
      error = error!(DataModel.set(DataModel.new(5), "/a", 1))
      assert error.message =~ "the data model root is a primitive value"
    end

    test "a non-numeric segment on a list" do
      error = error!(DataModel.set(DataModel.new(%{"l" => [1]}), "/l/x", 2))
      assert error.message =~ "Cannot use non-numeric segment 'x' on an array"

      error = error!(DataModel.set(DataModel.new(%{"l" => [1]}), "/l/01", 2))
      assert error.message =~ "non-numeric segment '01'"
    end

    test "errors are atomic: the original model is untouched" do
      model = DataModel.new(%{"a" => %{"b" => 1}, "l" => [1]})

      error!(DataModel.set(model, "/a/b/c/d", 1))
      error!(DataModel.set(model, "/l/x/y", 1))

      assert DataModel.data(model) == %{"a" => %{"b" => 1}, "l" => [1]}
    end

    test "a failed write notifies nobody" do
      model = DataModel.new(%{"a" => 1})
      {:ok, model, _id, 1} = DataModel.subscribe(model, "/a")

      error!(DataModel.set(model, "/a/b", 2))
      assert DataModel.get(model, "/a") == {:ok, 1}
    end
  end

  describe "subscriptions" do
    test "subscribe returns the current value and a normalized path" do
      model = DataModel.new(%{"a" => %{"b" => 7}})
      assert {:ok, model, 1, 7} = DataModel.subscribe(model, "//a///b//")
      assert {:ok, model, 2, nil} = DataModel.subscribe(model, "/nothing")

      assert DataModel.subscriptions(model) == [{1, "/a/b"}, {2, "/nothing"}]
    end

    test "a write to the subscribed path notifies with the new value" do
      {:ok, model, id, _} = DataModel.subscribe(DataModel.new(), "/a")
      assert {_model, [{^id, "/a", 5}]} = set!(model, "/a", 5)
    end

    test "an unchanged value does not notify" do
      {:ok, model, _id, 5} = DataModel.subscribe(DataModel.new(%{"a" => 5}), "/a")
      assert {_model, []} = set!(model, "/a", 5)
    end

    test "writing an ancestor notifies a descendant only if its value changed" do
      model = DataModel.new(%{"user" => %{"name" => "Ada", "age" => 36}})
      {:ok, model, name_id, _} = DataModel.subscribe(model, "/user/name")
      {:ok, model, age_id, _} = DataModel.subscribe(model, "/user/age")

      {_model, notifications} = set!(model, "/user", %{"name" => "Grace", "age" => 36})
      assert notifications == [{name_id, "/user/name", "Grace"}]
      refute Enum.any?(notifications, &match?({^age_id, _, _}, &1))
    end

    test "writing a descendant notifies an ancestor with the whole value" do
      {:ok, model, id, _} = DataModel.subscribe(DataModel.new(%{"user" => %{"n" => 1}}), "/user")
      assert {_model, [{^id, "/user", %{"n" => 2}}]} = set!(model, "/user/n", 2)
    end

    test "siblings and prefix-lookalikes are not notified" do
      model = DataModel.new(%{"foo" => 1, "foobar" => 2})
      {:ok, model, _, _} = DataModel.subscribe(model, "/foobar")
      {:ok, model, _, _} = DataModel.subscribe(model, "/other")

      assert {_model, []} = set!(model, "/foo", 99)
    end

    test "a root write notifies every changed subscription" do
      model = DataModel.new(%{"a" => 1, "b" => 2})
      {:ok, model, a, _} = DataModel.subscribe(model, "/a")
      {:ok, model, b, _} = DataModel.subscribe(model, "/b")
      {:ok, model, root, _} = DataModel.subscribe(model, "/")

      assert {_model, notifications} = set!(model, "/", %{"a" => 1, "b" => 3})
      assert notifications == [{b, "/b", 3}, {root, "/", %{"a" => 1, "b" => 3}}]
      refute Enum.any?(notifications, &match?({^a, _, _}, &1))
    end

    test "a delete notifies with nil" do
      {:ok, model, id, 1} = DataModel.subscribe(DataModel.new(%{"a" => 1}), "/a")
      assert {_model, [{^id, "/a", nil}]} = set!(model, "/a", nil)
    end

    test "notifications are ordered by subscription id, repeats included" do
      {:ok, model, first, _} = DataModel.subscribe(DataModel.new(), "/a")
      {:ok, model, second, _} = DataModel.subscribe(model, "/a")

      assert {_model, [{^first, "/a", 1}, {^second, "/a", 1}]} = set!(model, "/a", 1)
    end

    test "unsubscribe and dispose stop notifications; data is kept" do
      {:ok, model, first, _} = DataModel.subscribe(DataModel.new(), "/a")
      {:ok, model, second, _} = DataModel.subscribe(model, "/a")

      model = DataModel.unsubscribe(model, first)
      assert {model, [{^second, "/a", 1}]} = set!(model, "/a", 1)

      disposed = DataModel.dispose(model)
      assert DataModel.subscriptions(disposed) == []
      assert DataModel.get(disposed, "/a") == {:ok, 1}
      assert {_model, []} = set!(disposed, "/a", 2)
    end

    test "unsubscribing an unknown id is ignored" do
      model = DataModel.new()
      assert DataModel.unsubscribe(model, 99) == model
    end

    test "subscription ids are never reused" do
      {:ok, model, 1, _} = DataModel.subscribe(DataModel.new(), "/a")
      model = DataModel.unsubscribe(model, 1)
      assert {:ok, _model, 2, _} = DataModel.subscribe(model, "/a")
    end

    test "a bad path is an error" do
      error!(DataModel.subscribe(DataModel.new(), "/__proto__"))
    end
  end

  # -- properties ----------------------------------------------------------------

  @tokens ~w(a b c d)

  defp path_gen do
    @tokens
    |> StreamData.member_of()
    |> StreamData.list_of(min_length: 1, max_length: 4)
    |> StreamData.map(&Pointer.build/1)
  end

  defp json_gen do
    StreamData.one_of([
      StreamData.integer(),
      StreamData.boolean(),
      StreamData.string(:alphanumeric, max_length: 6),
      StreamData.constant([]),
      StreamData.constant(%{})
    ])
  end

  property "set then get returns the value" do
    check all(path <- path_gen(), value <- json_gen()) do
      {:ok, model, _} = DataModel.set(DataModel.new(), path, value)
      assert DataModel.get(model, path) == {:ok, value}
      assert DataModel.has_path?(model, path) == {:ok, true}
    end
  end

  property "set then delete leaves the path absent" do
    check all(path <- path_gen(), value <- json_gen()) do
      {:ok, model, _} = DataModel.set(DataModel.new(), path, value)
      {:ok, model, _} = DataModel.delete(model, path)

      assert DataModel.get(model, path) == {:ok, nil}
      assert DataModel.has_path?(model, path) == {:ok, false}
    end
  end

  property "a write does not disturb disjoint paths" do
    check all(value <- json_gen()) do
      {:ok, model, _} = DataModel.set(DataModel.new(), "/left/x", 1)
      {:ok, model, _} = DataModel.set(model, "/right/y", value)

      assert DataModel.get(model, "/left/x") == {:ok, 1}
    end
  end

  property "notifications are exactly the subscriptions whose value changed" do
    writes = StreamData.list_of(StreamData.tuple({path_gen(), nullable_json()}), max_length: 8)
    watches = StreamData.list_of(path_gen(), min_length: 1, max_length: 5)

    check all(paths <- watches, steps <- writes) do
      model =
        Enum.reduce(paths, DataModel.new(), fn path, model ->
          {:ok, model, _id, _value} = DataModel.subscribe(model, path)
          model
        end)

      Enum.reduce(steps, model, fn {path, value}, model ->
        case DataModel.set(model, path, value) do
          {:ok, updated, notifications} ->
            assert notifications == expected_notifications(model, updated)
            updated

          {:error, %Error{category: :data}} ->
            model
        end
      end)
    end
  end

  defp nullable_json, do: StreamData.one_of([StreamData.constant(nil), json_gen()])

  defp expected_notifications(old, new) do
    Enum.flat_map(DataModel.subscriptions(new), fn {id, path} ->
      {:ok, before} = DataModel.get(old, path)
      {:ok, current} = DataModel.get(new, path)
      if before == current, do: [], else: [{id, path, current}]
    end)
  end
end

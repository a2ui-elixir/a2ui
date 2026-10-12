defmodule A2UICore.Resolution.DataContextTest do
  @moduledoc false
  use ExUnit.Case, async: true

  alias A2UICore.Resolution.DataContext

  doctest A2UICore.Resolution.DataContext

  describe "new/1" do
    test "defaults to the root scope" do
      assert DataContext.new().path == "/"
    end

    test "always ends with a slash" do
      assert DataContext.new("/user").path == "/user/"
      assert DataContext.new("/user/").path == "/user/"
    end
  end

  describe "nested/3" do
    test "joins the relative path and ignores a leading slash" do
      root = DataContext.new()

      assert DataContext.nested(root, "items/2").path == "/items/2/"
      assert DataContext.nested(root, "/items/2").path == "/items/2/"
    end

    test "scopes stack" do
      scope = DataContext.new() |> DataContext.nested("items/2") |> DataContext.nested("tags/0")
      assert scope.path == "/items/2/tags/0/"
    end

    test "keeps the parent and an explicit index" do
      root = DataContext.new()
      child = DataContext.nested(root, "items", 4)

      assert child.parent == root
      assert child.index == 4
    end
  end

  describe "index/1" do
    test "an explicit index wins" do
      scope = DataContext.new() |> DataContext.nested("items/9", 2)
      assert DataContext.index(scope) == 2
    end

    test "falls back to the numeric last segment" do
      scope = DataContext.new() |> DataContext.nested("items/7")
      assert DataContext.index(scope) == 7
    end

    test "walks outward through non-numeric scopes" do
      scope =
        DataContext.new()
        |> DataContext.nested("items/3")
        |> DataContext.nested("meta")

      assert DataContext.index(scope) == 3
    end

    test "is nil outside a collection" do
      assert DataContext.index(DataContext.new()) == nil
      assert DataContext.index(DataContext.new("/user")) == nil
    end
  end

  describe "resolve_path/2" do
    test "absolute paths are returned unchanged" do
      scope = DataContext.new("/items/1")
      assert DataContext.resolve_path(scope, "/other/path") == "/other/path"
    end

    test "relative paths join the scope" do
      scope = DataContext.new("/items/1")
      assert DataContext.resolve_path(scope, "name") == "/items/1/name"
      assert DataContext.resolve_path(scope, "a/b") == "/items/1/a/b"
    end

    test "empty and dot resolve to the scope itself" do
      scope = DataContext.new("/items/1")
      assert DataContext.resolve_path(scope, "") == "/items/1"
      assert DataContext.resolve_path(scope, ".") == "/items/1"
    end

    test "the root scope" do
      root = DataContext.new()
      assert DataContext.resolve_path(root, "name") == "/name"
      assert DataContext.resolve_path(root, "") == "/"
      assert DataContext.resolve_path(root, ".") == "/"
    end
  end
end

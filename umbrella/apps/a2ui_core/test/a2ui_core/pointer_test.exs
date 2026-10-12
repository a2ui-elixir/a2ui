defmodule A2UICore.PointerTest do
  @moduledoc false
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias A2UICore.Pointer

  doctest A2UICore.Pointer

  describe "parse/1" do
    test "splits and unescapes" do
      assert {:ok, ["a/b", "~c"]} = Pointer.parse("/a~1b/~0c")
    end

    test "drops empty segments (collapse)" do
      assert {:ok, ["a", "b"]} = Pointer.parse("//a///b//")
    end

    test "root and empty" do
      assert {:ok, []} = Pointer.parse("/")
      assert {:ok, []} = Pointer.parse("")
    end

    test "escape order: ~01 decodes to ~1" do
      assert {:ok, ["~1"]} = Pointer.parse("/~01")
    end

    test "forbidden segments" do
      assert {:error, %A2UICore.Error{category: :data}} = Pointer.parse("/__proto__/x")
      assert {:error, %A2UICore.Error{category: :data}} = Pointer.parse("/constructor")
      assert {:error, %A2UICore.Error{category: :data}} = Pointer.parse("/prototype")
    end

    test "forbidden check happens after unescaping" do
      # '~0__proto__' unescapes to '~__proto__' which is NOT forbidden
      assert {:ok, ["~__proto__"]} = Pointer.parse("/~0__proto__")
      # but literal '__proto__' is
      assert {:error, _} = Pointer.parse("/__proto__")
    end

    test "rejects non-binary" do
      assert {:error, %A2UICore.Error{category: :data}} = Pointer.parse(nil)
      assert {:error, %A2UICore.Error{category: :data}} = Pointer.parse(3)
    end
  end

  describe "build/1" do
    test "round trip: build ∘ parse = identity for well-formed pointers" do
      assert Pointer.build(["a/b", "~c"]) == "/a~1b/~0c"
      assert Pointer.build([]) == "/"
    end
  end

  describe "array_index?/1" do
    test "canonical numeric" do
      assert Pointer.array_index?("0")
      assert Pointer.array_index?("1")
      assert Pointer.array_index?("42")
      assert Pointer.array_index?("10000")
    end

    test "rejects leading zeros and non-numerics" do
      refute Pointer.array_index?("00")
      refute Pointer.array_index?("01")
      refute Pointer.array_index?("-1")
      refute Pointer.array_index?("a0")
      refute Pointer.array_index?(nil)
    end
  end

  describe "resolve/2" do
    test "absolute stays absolute" do
      assert Pointer.resolve("/a/b", "/x") == "/a/b"
    end

    test "relative joins context" do
      assert Pointer.resolve("name", "/user") == "/user/name"
      assert Pointer.resolve("name", "/user/") == "/user/name"
    end

    test "relative without context becomes root-relative" do
      assert Pointer.resolve("name", nil) == "/name"
    end
  end

  property "parse ∘ build round-trips" do
    check all(
            segments <- list_of(string(:printable, min_length: 1, max_length: 8), max_length: 6),
            Enum.all?(segments, fn seg ->
              not String.contains?(seg, "/") and
                not MapSet.member?(Pointer.forbidden_segments(), seg)
            end)
          ) do
      built = Pointer.build(segments)
      assert {:ok, parsed} = Pointer.parse(built)
      assert parsed == segments
    end
  end

  property "parse never raises for printable input" do
    check all(path <- string(:printable, max_length: 40)) do
      case Pointer.parse(path) do
        {:ok, _} -> :ok
        {:error, %{category: :data}} -> :ok
      end
    end
  end
end

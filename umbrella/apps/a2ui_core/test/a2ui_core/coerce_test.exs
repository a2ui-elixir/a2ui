defmodule A2UICore.CoerceTest do
  @moduledoc false
  use ExUnit.Case, async: true

  alias A2UICore.Coerce

  doctest A2UICore.Coerce

  describe "truthy?/1" do
    test "falsy values" do
      for value <- [nil, false, 0, 0.0, -0.0, "", [], %{}] do
        refute Coerce.truthy?(value), "expected #{inspect(value)} to be falsy"
      end
    end

    test "truthy values" do
      for value <- [true, 1, -1, 0.5, "0", "false", [nil], %{"a" => nil}] do
        assert Coerce.truthy?(value), "expected #{inspect(value)} to be truthy"
      end
    end
  end

  describe "to_string/1" do
    test "scalars" do
      assert Coerce.to_string(nil) == ""
      assert Coerce.to_string(true) == "true"
      assert Coerce.to_string(false) == "false"
      assert Coerce.to_string("text") == "text"
      assert Coerce.to_string(42) == "42"
      assert Coerce.to_string(-7) == "-7"
    end

    test "floats use the shortest round-trip form" do
      assert Coerce.to_string(1.5) == "1.5"
      assert Coerce.to_string(1.0) == "1.0"
      assert Coerce.to_string(0.1) == "0.1"
      assert Coerce.to_string(100.0) == "100.0"
      assert Coerce.to_string(-0.25) == "-0.25"
      assert Coerce.to_string(-0.0) == "-0.0"
    end

    test "float exponents follow Python's repr" do
      assert Coerce.to_string(1.0e16) == "1e+16"
      assert Coerce.to_string(1.5e16) == "1.5e+16"
      assert Coerce.to_string(1.0e15) == "1000000000000000.0"
      assert Coerce.to_string(0.0001) == "0.0001"
      assert Coerce.to_string(0.00001) == "1e-05"
      assert Coerce.to_string(1.5e-7) == "1.5e-07"
      assert Coerce.to_string(1.0e100) == "1e+100"
    end

    test "containers are compact JSON" do
      assert Coerce.to_string([1, "a", nil]) == ~s([1,"a",null])
      assert Coerce.to_string(%{"a" => [true]}) == ~s({"a":[true]})
    end

    test "anything else is inspected" do
      assert Coerce.to_string(:atom) == ":atom"
    end
  end

  describe "decompose/1" do
    test "returns sign, coefficient and exponent without trailing zeros" do
      assert Coerce.decompose(1234.5) == {"", 12_345, -1}
      assert Coerce.decompose(-0.001) == {"-", 1, -3}
      assert Coerce.decompose(1.0e20) == {"", 1, 20}
      assert Coerce.decompose(100.0) == {"", 1, 2}
      assert Coerce.decompose(0.0) == {"", 0, 0}
      assert Coerce.decompose(-0.0) == {"-", 0, 0}
    end
  end

  describe "to_float/1" do
    test "numbers and booleans" do
      assert Coerce.to_float(2) == {:ok, 2.0}
      assert Coerce.to_float(2.5) == {:ok, 2.5}
      assert Coerce.to_float(true) == {:ok, 1.0}
      assert Coerce.to_float(false) == {:ok, 0.0}
    end

    test "numeric strings" do
      assert Coerce.to_float("42") == {:ok, 42.0}
      assert Coerce.to_float(" 42.5 ") == {:ok, 42.5}
      assert Coerce.to_float("+1.5") == {:ok, 1.5}
      assert Coerce.to_float("-.5") == {:ok, -0.5}
      assert Coerce.to_float("5.") == {:ok, 5.0}
      assert Coerce.to_float("1e3") == {:ok, 1000.0}
      assert Coerce.to_float("2.5E-1") == {:ok, 0.25}
    end

    test "overflowing literals fall back to zero" do
      assert Coerce.to_float("1e999") == {:ok, 0.0}
    end

    test "non-numeric input" do
      for value <- ["", "abc", "1.2.3", "inf", "nan", "-Infinity", nil, [], %{}] do
        assert Coerce.to_float(value) == :error, "expected #{inspect(value)} to be rejected"
      end
    end
  end

  describe "to_integer/1" do
    test "integers, floats and booleans" do
      assert Coerce.to_integer(7) == {:ok, 7}
      assert Coerce.to_integer(7.9) == {:ok, 7}
      assert Coerce.to_integer(-7.9) == {:ok, -7}
      assert Coerce.to_integer(true) == {:ok, 1}
      assert Coerce.to_integer(false) == {:ok, 0}
    end

    test "integer literals" do
      assert Coerce.to_integer("12") == {:ok, 12}
      assert Coerce.to_integer(" -12 ") == {:ok, -12}
      assert Coerce.to_integer("+12") == {:ok, 12}
    end

    test "everything else" do
      for value <- ["1.5", "", "abc", nil, [], %{}] do
        assert Coerce.to_integer(value) == :error, "expected #{inspect(value)} to be rejected"
      end
    end
  end
end

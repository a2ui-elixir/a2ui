defmodule A2UIConformance.PyStrTest do
  @moduledoc false
  # Expected values are what CPython 3 prints for the same JSON values.

  use ExUnit.Case, async: true

  alias A2UIConformance.PyStr

  describe "str/1" do
    test "strings are bare, everything else is repr" do
      assert PyStr.str("text") == "text"
      assert PyStr.str(1) == "1"
      assert PyStr.str("1") == "1"
      assert PyStr.str(nil) == "None"
      assert PyStr.str(true) == "True"
    end

    test "a string and the number it spells are equal only at the top level" do
      assert PyStr.str("1") == PyStr.str(1)
      refute PyStr.str(["1"]) == PyStr.str([1])
    end
  end

  describe "repr/1" do
    test "scalars" do
      assert PyStr.repr(nil) == "None"
      assert PyStr.repr(true) == "True"
      assert PyStr.repr(false) == "False"
      assert PyStr.repr(-42) == "-42"
    end

    test "floats use the shortest round-trip form" do
      expected = [
        {1.0, "1.0"},
        {0.1, "0.1"},
        {-2.5, "-2.5"},
        {100.0, "100.0"},
        {0.0001, "0.0001"},
        {123_456_789.123, "123456789.123"},
        {1.0e15, "1000000000000000.0"},
        {-0.0, "-0.0"}
      ]

      for {value, text} <- expected, do: assert(PyStr.repr(value) == text)
    end

    test "floats switch to scientific notation outside [1e-4, 1e16)" do
      expected = [
        {1.0e16, "1e+16"},
        {1.5e-7, "1.5e-07"},
        {1.0e-5, "1e-05"},
        {1.0e22, "1e+22"},
        {1.5e300, "1.5e+300"},
        {12_345_678_901_234_567_890.0, "1.2345678901234567e+19"}
      ]

      for {value, text} <- expected, do: assert(PyStr.repr(value) == text)
    end

    test "strings pick their quote like Python" do
      assert PyStr.repr("plain") == "'plain'"
      assert PyStr.repr("it's") == ~s("it's")
      assert PyStr.repr(~s(a'b"c)) == ~S('a\'b"c')
      assert PyStr.repr("ünï") == "'ünï'"
    end

    test "control characters and backslashes are escaped" do
      assert PyStr.repr("a\nb") == ~S('a\nb')
      assert PyStr.repr("tab\there") == ~S('tab\there')
      assert PyStr.repr("\r") == ~S('\r')
      assert PyStr.repr(<<1>>) == ~S('\x01')
      assert PyStr.repr(<<0x7F>>) == ~S('\x7f')
      assert PyStr.repr("back\\slash") == ~S('back\\slash')
    end

    test "lists keep order, maps print sorted keys" do
      assert PyStr.repr([1, "a", nil, true, false, 1.5]) == "[1, 'a', None, True, False, 1.5]"
      assert PyStr.repr(%{"k" => "v", "a" => %{"z" => nil}}) == "{'a': {'z': None}, 'k': 'v'}"
      assert PyStr.repr([]) == "[]"
      assert PyStr.repr(%{}) == "{}"
    end

    test "other terms fall back to inspect" do
      assert PyStr.repr(:atom) == ":atom"
    end
  end
end

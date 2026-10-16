defmodule A2UIAgent.PayloadFixerTest do
  use ExUnit.Case, async: true

  alias A2UIAgent.PayloadFixer

  doctest A2UIAgent.PayloadFixer

  @backslash <<92>>

  test "reads lists and wraps a single value" do
    assert PayloadFixer.parse_and_fix(~s([{"a": 1}, {"b": 2}])) ==
             {:ok, [%{"a" => 1}, %{"b" => 2}]}

    assert PayloadFixer.parse_and_fix(~s({"a": 1})) == {:ok, [%{"a" => 1}]}
    assert PayloadFixer.parse_and_fix("3") == {:ok, [3]}
  end

  test "drops trailing commas, nested too, but not commas inside strings" do
    assert PayloadFixer.parse_and_fix(~s([{"a": [1, 2,], "b": {"c": 1,},},])) ==
             {:ok, [%{"a" => [1, 2], "b" => %{"c" => 1}}]}

    assert PayloadFixer.parse_and_fix(~s({"text": "Hello, world", "list": ["a,b", "c"]})) ==
             {:ok, [%{"text" => "Hello, world", "list" => ["a,b", "c"]}]}
  end

  test "straightens curly quotes" do
    assert PayloadFixer.parse_and_fix(~s({"type": “Text”, "other": "Value’s ‘x’"})) ==
             {:ok, [%{"type" => "Text", "other" => "Value's 'x'"}]}
  end

  test "accepts control characters inside strings, and valid escapes" do
    assert PayloadFixer.parse_and_fix(~s({"text": "line one\nline\ttwo"})) ==
             {:ok, [%{"text" => "line one\nline\ttwo"}]}

    escaped = ~s({"text": "a) <> @backslash <> ~s(nb) <> @backslash <> ~s("c"})
    assert PayloadFixer.parse_and_fix(escaped) == {:ok, [%{"text" => "a\nb\"c"}]}
  end

  test "a payload that does not read is a parse error" do
    assert {:error, %A2UICore.Error{category: :parse, message: "Failed to parse JSON: " <> _}} =
             PayloadFixer.parse_and_fix("invalid_json")
  end

  test "an unescaped backslash gets a hint with its line and column" do
    payload = ~s({"formula": ") <> @backslash <> "approx " <> @backslash <> ~s(Delta x"})

    assert {:error, %A2UICore.Error{category: :parse, message: message}} =
             PayloadFixer.parse_and_fix(payload)

    assert message =~ "escape: line 1 column 14 (char 13)"
    assert message =~ "Unescaped backslash found at line 1, col 14."

    multiline = ~s({\n  "é": "ok",\n  "f": "x) <> @backslash <> ~s(q"\n})
    assert {:error, %A2UICore.Error{message: message}} = PayloadFixer.parse_and_fix(multiline)
    assert message =~ "line 3 column 10 (char 24)"
  end
end

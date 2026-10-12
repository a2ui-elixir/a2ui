defmodule A2UICore.ExpressionTest do
  @moduledoc false
  use ExUnit.Case, async: true

  alias A2UICore.Error
  alias A2UICore.Expression

  doctest A2UICore.Expression

  defp parse!(template), do: Expression.parse!(template)

  defp message(template) do
    assert {:error, %Error{category: :expression, message: message}} = Expression.parse(template)
    message
  end

  describe "literal text" do
    test "empty template has no parts" do
      assert parse!("") == []
    end

    test "text without markers is a single part" do
      assert parse!("plain text") == ["plain text"]
    end

    test "multibyte text survives untouched" do
      assert parse!("héllo ${/n} 日本語 🎉") == ["héllo ", %{"path" => "/n"}, " 日本語 🎉"]
    end

    test "an escaped marker yields the literal marker" do
      assert parse!("cost: \\${5}") |> Enum.join() == "cost: ${5}"
    end

    test "a lone dollar sign or brace is text" do
      assert parse!("$5 {x}") |> Enum.join() == "$5 {x}"
    end
  end

  describe "bindings" do
    test "absolute and relative paths" do
      assert parse!("${/user/name}") == [%{"path" => "/user/name"}]
      assert parse!("${name}") == [%{"path" => "name"}]
      assert parse!("${a.b-c}") == [%{"path" => "a.b-c"}]
    end

    test "whitespace around the content is ignored" do
      assert parse!("${  /x  }") == [%{"path" => "/x"}]
    end

    test "non-ASCII identifiers" do
      assert parse!("${/名前}") == [%{"path" => "/名前"}]
      assert parse!("${größe}") == [%{"path" => "größe"}]
    end

    test "adjacent interpolations keep their order" do
      assert parse!("${/a}${/b}") == [%{"path" => "/a"}, %{"path" => "/b"}]
    end

    test "an empty interpolation yields nothing" do
      assert parse!("a${}b") == ["a", "b"]
      assert parse!("${   }") == []
    end
  end

  describe "literals in interpolations" do
    test "quoted strings with both quote styles" do
      assert parse!("${'hi'}") == ["hi"]
      assert parse!(~S|${"hi"}|) == ["hi"]
    end

    test "string escapes" do
      assert parse!(~S|${'a\nb\tc\rd\'e'}|) == ["a\nb\tc\rd'e"]
    end

    test "braces inside quoted strings do not close the interpolation" do
      assert parse!("${'a}b'}") == ["a}b"]
    end

    test "integers, signs and floats" do
      assert parse!("${42}") == [42]
      assert parse!("${-7}") == [-7]
      assert parse!("${+3}") == [3]
      assert parse!("${1.5}") == [1.5]
      assert parse!("${-.5}") == [-0.5]
      assert parse!("${1e3}") == [1000.0]
      assert parse!("${2.5E-1}") == [0.25]
    end

    test "booleans and null" do
      assert parse!("${true}") == [true]
      assert parse!("${false}") == [false]
      assert parse!("${null}") == []
    end

    test "keyword prefixes are paths" do
      assert parse!("${trueish}") == [%{"path" => "trueish"}]
      assert parse!("${nullable}") == [%{"path" => "nullable"}]
    end
  end

  describe "function calls" do
    test "no arguments" do
      assert parse!("${now()}") == [%{"call" => "now", "args" => %{}, "returnType" => "any"}]
    end

    test "literal and binding arguments" do
      assert parse!("${add(a: 1, b: /x)}") == [
               %{
                 "call" => "add",
                 "args" => %{"a" => 1, "b" => %{"path" => "/x"}},
                 "returnType" => "any"
               }
             ]
    end

    test "commas are optional and whitespace is free" do
      assert parse!("${f( a : 1  b : 'two' )}") == [
               %{"call" => "f", "args" => %{"a" => 1, "b" => "two"}, "returnType" => "any"}
             ]
    end

    test "nested calls and nested interpolations as arguments" do
      assert [%{"call" => "outer", "args" => %{"x" => inner, "y" => %{"path" => "/p"}}}] =
               parse!("${outer(x: inner(v: 1), y: ${/p})}")

      assert inner == %{"call" => "inner", "args" => %{"v" => 1}, "returnType" => "any"}
    end

    test "a nested interpolation inside an interpolation" do
      assert parse!("${${/a}}") == [%{"path" => "/a"}]
    end
  end

  describe "errors" do
    test "unclosed interpolation" do
      assert message("${/x") == "Unclosed interpolation: missing '}'"
      assert message("a ${'x") =~ "Unclosed interpolation"
    end

    test "trailing characters" do
      assert message("${/a b}") =~ "Unexpected characters at end of expression: 'b'"
    end

    test "call without a closing parenthesis" do
      assert message("${f(a: 1}") =~ "Expected ')'"
    end

    test "argument without a colon" do
      assert message("${f(a 1)}") =~ "Expected ':' after argument name 'a' in function 'f'"
    end

    test "invalid and out-of-range numbers" do
      assert message("${1.2.3}") =~ "Invalid number literal"
      assert message("${1e}") =~ "Invalid number literal"
      assert message("${1e999}") =~ "out of range"
      assert message("${#{String.duplicate("9", 400)}}") =~ "out of range"
    end

    test "parse!/1 raises the error" do
      assert_raise Error, ~r/Unclosed interpolation/, fn -> Expression.parse!("${") end
    end
  end

  describe "limits" do
    test "templates over 10 000 characters are rejected" do
      assert {:ok, _parts} = Expression.parse(String.duplicate("a", 10_000))
      assert message(String.duplicate("a", 10_001)) =~ "exceeds maximum limit (10000)"
    end

    test "the length limit counts characters, not bytes" do
      assert {:ok, _parts} = Expression.parse(String.duplicate("日", 10_000))
      assert message(String.duplicate("日", 10_001)) =~ "template length (10001)"
    end

    test "more than 1 000 parts are rejected" do
      ok = String.duplicate("${/a}", 999)
      assert {:ok, parts} = Expression.parse(ok)
      assert length(parts) == 999

      assert message(String.duplicate("${/a}", 1_001)) =~
               "parts count exceeds maximum limit (1000)"
    end

    test "nesting beyond the depth limit is rejected" do
      depth = Expression.max_depth()
      assert depth == 100

      nested = fn levels ->
        String.duplicate("${", levels) <> "/a" <> String.duplicate("}", levels)
      end

      assert {:ok, [%{"path" => "/a"}]} = Expression.parse(nested.(depth - 1))
      assert message(nested.(depth + 5)) == "Max recursion depth reached in parse"
    end
  end
end

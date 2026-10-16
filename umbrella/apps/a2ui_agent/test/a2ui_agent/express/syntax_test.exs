defmodule A2UIAgent.Express.SyntaxTest do
  @moduledoc false
  use ExUnit.Case, async: true

  alias A2UIAgent.Express.Syntax

  doctest Syntax

  defp parse!(source) do
    assert {:ok, statements, []} = Syntax.parse(source)
    statements
  end

  defp errors(source) do
    {:ok, _statements, errors} = Syntax.parse(source)
    errors
  end

  describe "statements" do
    test "assignments to variables and data paths, and expressions" do
      assert parse!("a = 1\n$/b/c = 2\nfn(3)\n$\n") == [
               {:assign, "a", 1},
               {:assign, "$/b/c", 2},
               {:expr, {:call, "fn", [3], []}},
               {:expr, {:path, ""}}
             ]
    end

    test "line breaks of every kind" do
      assert parse!("a = 1\r\nb = \"x\\ry\"\rc = 3") ==
               [{:assign, "a", 1}, {:assign, "b", "x\ry"}, {:assign, "c", 3}]
    end

    test "semicolons, comments and blank lines separate nothing" do
      source = "a = 1; b = 2 # one\n// two\n/* three\n four */ c = 3"
      assert parse!(source) == [{:assign, "a", 1}, {:assign, "b", 2}, {:assign, "c", 3}]
      assert parse!("") == []
    end
  end

  describe "values" do
    test "literals" do
      assert parse!("a = [1, -2, 3.5, -0.25, true, false, null, _]") ==
               [{:assign, "a", [1, -2, 3.5, -0.25, true, false, nil, :skipped]}]
    end

    test "maps keep their key order and the last value of a repeated key" do
      assert parse!(~s|m = {b: 1, "a key": [], b: 2,}|) ==
               [{:assign, "m", {:map, [{"b", 2}, {"a key", []}]}}]

      assert parse!("m = {}") == [{:assign, "m", {:map, []}}]
    end

    test "calls split positional and keyword arguments" do
      assert parse!(~s|x = F(1, k="v", G(), k=2, _,)|) == [
               {:assign, "x", {:call, "F", [1, {:call, "G", [], []}, :skipped], [{"k", 2}]}}
             ]
    end

    test "checks, paths and variables" do
      assert parse!(~s|x = [?required, ?regex($/a, "^b$"), $item, name, ?len()]|) == [
               {:assign, "x",
                [
                  {:check, "required", []},
                  {:check, "regex", [{:path, "/a"}, "^b$"]},
                  {:path, "item"},
                  {:var, "name"},
                  {:check, "len", []}
                ]}
             ]
    end

    test "strings: standard, triple-quoted and raw" do
      source = ~S"""
      a = "x\n\t\\\"\q"
      b = \"""l1
      l2\n\"""
      c = r"C:\temp\n"
      d = R\"""raw\n
      ok\"""
      e = ""
      f = r"" g = "multi
      line"
      """

      assert parse!(source) == [
               {:assign, "a", "x\n\t\\\"\\q"},
               {:assign, "b", "l1\nl2\n"},
               {:assign, "c", ~S(C:\temp\n)},
               {:assign, "d", "raw\\n\nok"},
               {:assign, "e", ""},
               {:assign, "f", ""},
               {:assign, "g", "multi\nline"}
             ]
    end

    test "a raw prefix without a string is an identifier, and true is not a variable" do
      assert parse!("x = [r, R, rx, trueish, nullable, _x]") ==
               [
                 {:assign, "x",
                  [var: "r", var: "R", var: "rx", var: "trueish", var: "nullable", var: "_x"]}
               ]
    end

    test "a raw string cannot span lines; a standard string can" do
      assert parse!("x = r\"ab\ncd\"") == [{:assign, "x", {:var, "r"}}, {:expr, "ab\ncd"}]
      refute Syntax.identifier?(nil)
    end

    test "an unterminated triple string falls back to an empty string" do
      assert {:ok, [], [{1, _, _, _} | _]} = Syntax.parse(~s|a = """abc|)
    end

    test "an unterminated raw triple string reads as an empty raw string" do
      assert {:ok, [], [{1, _, _, _} | _]} = Syntax.parse(~s|x = r"""abc|)
    end
  end

  describe "errors" do
    test "a character no token starts with is a lexer error" do
      assert [{1, 4, "token recognition error at: '@'", :lexer} | _] = errors("a = @")
      assert [{1, 4, _, :lexer} | _] = errors("a = /* never closed")
      assert [{1, 4, _, :lexer} | _] = errors("a = ?")
      assert [{1, 4, _, :lexer} | _] = errors("a = -")
      assert [{1, 4, _, :lexer} | _] = errors(~s|a = "open|)

      assert [{1, 4, "token recognition error at: '\uFFFD'", :lexer} | _] =
               errors(<<"a = ", 0xFF>>)
    end

    test "a token out of place is a parser error" do
      assert [{1, 6, "mismatched input ',' expecting an expression", :parser}] =
               errors("a = F(,)")

      assert [{1, 7, "mismatched input '<EOF>' expecting ',' or ')'", :parser}] =
               errors("a = F(1")

      assert [{1, 6, "mismatched input '<EOF>' expecting ',' or ']'", :parser}] = errors("a = [1")
      assert [{1, 7, _, :parser}] = errors("a = {k 1}")
      assert [{1, 5, "mismatched input '1' expecting a map key", :parser}] = errors("a = {1: 2}")

      assert [{1, 10, "mismatched input 'x' expecting ',' or '}'", :parser}] =
               errors("a = {k: 1 x}")

      assert [{1, 10, "mismatched input '}' expecting an expression", :parser}] =
               errors("a = {k: 1}}")

      assert [{1, 4, "mismatched input '=' expecting an expression", :parser}] = errors("a = = 1")

      assert [{1, 11, "mismatched input '=' expecting ',' or ')'", :parser}] =
               errors("a = F(null = 1)")
    end

    test "statements before the first error's line are kept" do
      assert {:ok, [{:assign, "a", 1}], [{3, _, _, :parser}]} = Syntax.parse("a = 1\n\nb = [")
      assert {:ok, [], [{1, _, _, :lexer}]} = Syntax.parse("a = 1 @")

      assert {:ok, [{:assign, "a", 1}], [{2, _, _, :parser}, {3, _, _, :lexer}]} =
               Syntax.parse("a = 1\nb = (\n@")
    end

    test "describes the tokens it did not expect" do
      for {source, text} <- [
            {"a = F(1 2)", "'2'"},
            {~s|a = F(1 "s")|, ~s("s")},
            {"a = F(1 $p)", "'$p'"},
            {"a = F(1 ?c)", "'?c'"},
            {"a = F(1 _)", "'_'"},
            {"a = F(1 null)", "'null'"},
            {"a = F(1 true)", "'true'"},
            {"a = F(1 x)", "'x'"},
            {"a = F(1 :)", "':'"},
            {"a = F(1 (", "'('"}
          ] do
        assert [{_, _, message, :parser}] = errors(source)
        assert message == "mismatched input #{text} expecting ',' or ')'"
      end
    end
  end
end

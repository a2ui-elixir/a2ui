defmodule A2UICore.JMESPathTest do
  @moduledoc false
  use ExUnit.Case, async: true

  alias A2UICore.JMESPath

  doctest A2UICore.JMESPath

  @data %{
    "people" => [
      %{"name" => "Ada", "age" => 36, "tags" => ["math", "code"]},
      %{"name" => "Alan", "age" => 41, "tags" => ["code"]},
      %{"name" => "Grace", "age" => 29, "tags" => []}
    ],
    "matrix" => [[1, 2], [3, [4]], 5],
    "settings" => %{"theme" => "dark", "size" => 2},
    "empty" => %{},
    "text" => "héllo",
    "dotted.key" => 1,
    "é" => "accent"
  }

  defp search!(expression, data \\ @data) do
    assert {:ok, value} = JMESPath.search(expression, data)
    value
  end

  defp error_code(expression, data \\ @data) do
    assert {:error, %A2UICore.Error{category: :expression, code: code}} =
             JMESPath.search(expression, data)

    code
  end

  test "fields, subexpressions, indices and quoted identifiers" do
    assert search!("settings.theme") == "dark"
    assert search!("settings.missing.deeper") == nil
    assert search!("people[0].name") == "Ada"
    assert search!("people[-1].name") == "Grace"
    assert search!("people[7]") == nil
    assert search!("matrix[1][1]") == [4]
    assert search!("people[-7]") == nil
    assert search!(~S("dotted.key")) == 1
    assert search!(~S(settings."theme")) == "dark"
    assert search!("text[0]") == nil
    assert search!("@") == @data
  end

  test "slices follow Python's rules" do
    list = Enum.to_list(0..9)
    assert search!("[2:5]", list) == [2, 3, 4]
    assert search!("[::3]", list) == [0, 3, 6, 9]
    assert search!("[::-1]", list) == Enum.reverse(list)
    assert search!("[-3:]", list) == [7, 8, 9]
    assert search!("[8:2:-2]", list) == [8, 6, 4]
    assert search!("[:-20]", list) == []
    assert search!("[20:]", list) == []
    assert search!("[-20::-1]", list) == []
    assert search!("[:20:-1]", list) == []
    assert search!("[5:1]", list) == []
    assert search!("[1:3]", %{}) == nil
    assert error_code("[::0]", list) == "JMESPATH_INVALID_VALUE"
  end

  test "projections, flatten and filters" do
    assert search!("people[*].name") == ["Ada", "Alan", "Grace"]
    assert MapSet.new(search!("settings.*")) == MapSet.new([2, "dark"])
    assert search!("people[*].tags[]") == ["math", "code", "code"]
    assert search!("matrix[]") == [1, 2, 3, [4], 5]
    assert search!("matrix[][]") == [1, 2, 3, 4, 5]
    assert search!("people[?age > `30`].name") == ["Ada", "Alan"]
    assert search!("people[?contains(tags, 'math')].name") == ["Ada"]
    assert search!("people[?tags].name") == ["Ada", "Alan"]
    assert search!("people[*].missing") == []
    assert search!("settings[*]") == nil
    assert search!("people.*") == nil
    assert search!("text[]") == nil
    assert search!("settings[?x]") == nil
    assert search!("people[*].name | [0]") == "Ada"
    assert search!("people[1:].name") == ["Alan", "Grace"]
    assert search!("*") |> length() == map_size(@data)
    assert search!("[*]", [1, nil, false]) == [1, false]
    assert search!("[?@]", [1, nil, false, "", "x"]) == [1, "x"]
    assert search!("[][]", [[1, [2]], 3]) == [1, 2, 3]
    assert search!("[?a == `1`][]", [%{"a" => 1}, %{"a" => 2}]) == [%{"a" => 1}]
  end

  test "multi-select lists and hashes" do
    assert search!("people[0].[name, age]") == ["Ada", 36]

    assert search!("people[*].{n: name, \"first tag\": tags[0]}") == [
             %{"n" => "Ada", "first tag" => "math"},
             %{"n" => "Alan", "first tag" => "code"},
             %{"n" => "Grace", "first tag" => nil}
           ]

    assert search!("missing.[a]") == nil
    assert search!("missing.{a: a}") == nil
    assert search!("[settings.theme, text]") == ["dark", "héllo"]
    assert search!("[n, *]", %{"n" => 1}) == [1, [1]]
    assert search!("{a: settings.size}") == %{"a" => 2}
  end

  test "boolean operators and truthiness" do
    assert search!("missing || settings.theme") == "dark"
    assert search!("empty || 'fallback'") == "fallback"
    assert search!("settings.theme && settings.size") == 2
    assert search!("empty && settings.size") == %{}
    assert search!("!empty") == true
    assert search!("!settings") == false
    assert search!("!`0`") == false
    assert search!("(missing || settings).theme") == "dark"
  end

  test "comparisons: equality is JSON equality, ordering is for numbers" do
    assert search!("`1` == `1.0`")
    refute search!("`1` == `true`")
    assert search!(~S(`[1, {"a": 2}]` == `[1.0, {"a": 2.0}]`))
    refute search!(~S(`{"a": 1}` == `{"b": 1}`))
    refute search!("`[1]` == `[1, 2]`")
    assert search!("settings.theme != 'light'")
    assert search!("`2` >= `2`")
    assert search!("`1` <= `2`")
    refute search!("`1` > `2`")
    assert search!("`1` < `2`")
    assert search!("'a' < 'b'") == nil
  end

  test "literals and raw strings" do
    assert search!("`{\"a\": [1, 2.5, null, true]}`") == %{"a" => [1, 2.5, nil, true]}
    assert search!("`foo`") == "foo"
    assert search!("`[1`") == "[1"
    assert search!(~S('it\'s')) == "it's"
    assert search!(~S('back\\slash')) == ~S(back\\slash)
    assert search!(~S(") <> <<92, ?u>> <> ~S(00e9")) == "accent"
    assert search!("`\"\\`\"`") == "`"
  end

  test "functions" do
    assert search!("abs(`-3`)") == 3
    assert search!("avg(`[1, 2, 3]`)") == 2.0
    assert search!("avg(`[]`)") == nil
    assert search!("ceil(`1.2`)") == 2
    assert search!("floor(`1.8`)") == 1
    assert search!("contains('foobar', 'oba')")
    refute search!("contains('foobar', `1`)")
    assert search!("contains(`[1, 2]`, `2.0`)")
    assert search!("ends_with(text, 'llo')")
    assert search!("starts_with(text, 'hé')")
    assert search!("join(', ', people[*].name)") == "Ada, Alan, Grace"
    assert search!("keys(settings)") |> Enum.sort() == ["size", "theme"]
    assert MapSet.new(search!("values(settings)")) == MapSet.new([2, "dark"])
    assert search!("length(text)") == 5
    assert search!("length(people)") == 3
    assert search!("length(settings)") == 2
    assert search!("map(&name, people)") == ["Ada", "Alan", "Grace"]
    assert search!("map(&missing, people)") == [nil, nil, nil]
    assert search!("max(people[*].age)") == 41
    assert search!("min(people[*].name)") == "Ada"
    assert search!("max(`[]`)") == nil
    assert search!("min(`[]`)") == nil
    assert search!("max_by(people, &age).name") == "Alan"
    assert search!("min_by(people, &age).name") == "Grace"
    assert search!("min_by(`[]`, &age)") == nil
    assert search!("sort_by(people, &name)[*].name") == ["Ada", "Alan", "Grace"]
    assert search!("sort_by(`[]`, &name)") == []
    assert search!("merge(settings, `{\"size\": 3}`)") == %{"theme" => "dark", "size" => 3}
    assert search!("not_null(missing, `null`, 'x')") == "x"
    assert search!("reverse(text)") == "olléh"
    assert search!("reverse(`[1, 2]`)") == [2, 1]
    assert search!("sort(`[3, 1.5, 2]`)") == [1.5, 2, 3]
    assert search!("sum(`[1, 2.5]`)") == 3.5
    assert search!("to_array(`1`)") == [1]
    assert search!("to_array(`[1]`)") == [1]
    assert search!("to_number('42')") == 42
    assert search!("to_number('4.5')") == 4.5
    assert search!("to_number('x')") == nil
    assert search!("to_number(`7`)") == 7
    assert search!("to_number(`true`)") == nil
    assert search!("to_string(`[1, \"a\"]`)") == ~S([1,"a"])
    assert search!("to_string('a')") == "a"
    assert search!("type(`null`)") == "null"

    assert search!("[type(`1`), type('a'), type(`true`), type(`[]`), type(`{}`)]") ==
             ["number", "string", "boolean", "array", "object"]
  end

  test "function argument checks" do
    assert error_code("abs('a')") == "JMESPATH_INVALID_TYPE"
    assert error_code("sum(`[1, \"a\"]`)") == "JMESPATH_INVALID_TYPE"
    assert error_code("join(', ', `[1]`)") == "JMESPATH_INVALID_TYPE"
    assert error_code("map(name, people)") == "JMESPATH_INVALID_TYPE"
    assert error_code("sort_by(people, &tags)") == "JMESPATH_INVALID_TYPE"
    assert error_code(~S|max_by(`[{"a": 1}, {"a": "b"}]`, &a)|) == "JMESPATH_INVALID_TYPE"
    assert search!("type(&a)") == "expref"
    assert error_code("abs(&a)") == "JMESPATH_INVALID_TYPE"
    assert error_code("abs()") == "JMESPATH_INVALID_ARITY"
    assert error_code("abs(`1`, `2`)") == "JMESPATH_INVALID_ARITY"
    assert error_code("merge()") == "JMESPATH_INVALID_ARITY"
    assert error_code("nope(`1`)") == "JMESPATH_UNKNOWN_FUNCTION"

    assert {:error, error} = JMESPath.search("abs('a')", %{})
    assert error.message =~ "In function abs(), invalid type for value: \"a\""
  end

  test "syntax errors" do
    for expression <- [
          "",
          "foo.",
          "foo[",
          "[1",
          "foo]",
          "{a}",
          "{a: b",
          "{a: b c: d}",
          "f(a b)",
          "\"f\"(a)",
          "'open",
          "\"open",
          "foo =",
          "-",
          "#",
          "foo.1",
          "[1:2:3:4]",
          "[:a]",
          "foo[0:1]bar",
          "foo.*bar",
          "{1: a}",
          "a .. b",
          "!",
          "[a, b",
          "(a",
          "\"\\x\"",
          "foo[*",
          "foo{",
          "[a b]",
          "`a\"b`",
          "5(a)",
          "foo[?a",
          "@(a)",
          "foo[*]*"
        ] do
      assert error_code(expression) == "JMESPATH_SYNTAX", "expected a syntax error: #{expression}"
    end
  end

  test "an expression reference on its own evaluates to null" do
    assert search!("&foo") == nil
  end

  test "non-ASCII input is reported as an unknown token" do
    assert error_code("é") == "JMESPATH_SYNTAX"
    assert error_code(<<0xFF>>) == "JMESPATH_SYNTAX"
  end
end

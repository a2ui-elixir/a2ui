defmodule A2UIAgent.DirectJson.JsonReaderTest do
  @moduledoc false
  use ExUnit.Case, async: true

  alias A2UIAgent.DirectJson.JsonReader

  doctest JsonReader

  # A `\uXXXX` escape, built at run time so that the reader gets it as
  # escape text.
  defp esc(hex), do: <<?\\, ?u>> <> hex

  defp quoted(text), do: "\"" <> text <> "\""

  describe "read/1" do
    test "reads JSON values" do
      assert JsonReader.read(~s({"a": [1, -2.5, 1e2, 1E-1, 2.5e+1, true, false, null, "x"]})) ==
               {:ok, %{"a" => [1, -2.5, 100.0, 0.1, 25.0, true, false, nil, "x"]}}

      assert JsonReader.read(" 42 ") == {:ok, 42}
      assert JsonReader.read("[]") == {:ok, []}
      assert JsonReader.read("{ }") == {:ok, %{}}
    end

    test "accepts trailing commas and raw line breaks and tabs in strings" do
      assert JsonReader.read(~s({"a": [1, 2,], "b": "line\none\ttab",})) ==
               {:ok, %{"a" => [1, 2], "b" => "line\none\ttab"}}
    end

    test "reads escapes" do
      text = ~S(\" \\ \/ \b \f \n \r \t ) <> esc("00e9") <> " " <> esc("d83d") <> esc("de80")
      assert JsonReader.read(quoted(text)) == {:ok, "\" \\ / \b \f \n \r \t é 🚀"}
    end

    test "an unpaired surrogate escape reads as U+FFFD" do
      assert JsonReader.read(quoted("a" <> esc("d83d") <> "b")) == {:ok, "a�b"}
      assert JsonReader.read(quoted(esc("dc00"))) == {:ok, "�"}
      assert JsonReader.read(quoted(esc("d83d") <> esc("0041"))) == {:ok, "�A"}
    end

    test "curly quotes are straightened only when the text does not read as it is" do
      assert JsonReader.read(~s({“a”: “it’s”})) == {:ok, %{"a" => "it's"}}
      assert JsonReader.read(~s({"a": "“b”"})) == {:ok, %{"a" => "“b”"}}
      assert {:error, _reason} = JsonReader.read(~s({“a”: x}))
    end

    test "reports where the text stops reading, counted in characters" do
      assert JsonReader.read(~s({"é": x})) ==
               {:error, "Invalid JSON at 6: unexpected character 'x'"}

      assert JsonReader.read(~s({"a":1} x)) ==
               {:error, "Invalid JSON at 8: unexpected text after the JSON value"}
    end

    test "rejects what is not JSON" do
      for {text, reason} <- [
            {~s({"a" 1}), "expected ':' after key 'a'"},
            {~s({1: 2}), "expected a key"},
            {~s({"a": 1 "b": 2}), "expected ',' or '}'"},
            {"[1 2]", "expected ',' or ']'"},
            {~S("\x"), "invalid escape '\\x'"},
            {<<?", ?\\, 0xFF, ?">>, "invalid escape"},
            {~S("\uZZZZ"), "invalid unicode escape"},
            {"01", "invalid number '01'"},
            {"-", "invalid number '-'"},
            {"tru", "unexpected character 't'"},
            {~s({"a": 1), "unexpected end of the JSON text"},
            {~s("abc), "unexpected end of the JSON text"},
            {~s([1,), "unexpected end of the JSON text"},
            {"", "unexpected end of the JSON text"}
          ] do
        assert {:error, "Invalid JSON at " <> message} = JsonReader.read(text)
        assert message =~ ": " <> reason, "#{inspect(text)}: #{message}"
      end
    end
  end

  describe "read_partial_items/3" do
    test "reads the messages of a finished list" do
      assert JsonReader.read_partial_items(~s([{"a": 1}, {"b": 2}]), []) ==
               [{%{"a" => 1}, true}, {%{"b" => 2}, true}]

      assert JsonReader.read_partial_items(~s([1, 2e1]), []) == [{1, true}, {20.0, true}]
      assert JsonReader.read_partial_items("", []) == []
      assert JsonReader.read_partial_items("  [ ", []) == []
    end

    test "an unfinished message is closed where the text ends" do
      assert JsonReader.read_partial_items(~s([{"a": 1}, {"b": [1, {"c": true},), []) ==
               [{%{"a" => 1}, true}, {%{"b" => [1, %{"c" => true}]}, false}]

      assert JsonReader.read_partial_items(~s([{"a": 1}, {"b": [1, 2), []) ==
               [{%{"a" => 1}, true}]

      assert JsonReader.read_partial_items(~s([{"a": {"b": null}), []) ==
               [{%{"a" => %{"b" => nil}}, false}]

      assert JsonReader.read_partial_items(~s([{"a": 1, ), []) == [{%{"a" => 1}, false}]
      assert JsonReader.read_partial_items("[{", []) == [{%{}, false}]
    end

    test "a value that may still grow leaves its message out" do
      for tail <- [~s({"b": 12), ~s({"b": tr), ~s({"b), ~s({"b" ), ~s({"b": ), ~s({"b": "x)] do
        assert JsonReader.read_partial_items(~s([{"a": 1}, ) <> tail, []) ==
                 [{%{"a" => 1}, true}],
               tail
      end
    end

    test "a string under a progressive key is cut where the text ends, unless it is a URL" do
      assert JsonReader.read_partial_items(~s([{"text": "Hel), ["text"]) ==
               [{%{"text" => "Hel"}, false}]

      assert JsonReader.read_partial_items(~s([{"text": "a) <> "\\", ["text"]) ==
               [{%{"text" => "a"}, false}]

      assert JsonReader.read_partial_items(~s([{"text": "caf) <> <<?\\, ?u>> <> "00", ["text"]) ==
               [{%{"text" => "caf"}, false}]

      for url <- ["http://ex", "https://ex", "data:image/png"] do
        assert JsonReader.read_partial_items(~s([{"url": "#{url}), ["url"]) == []
      end
    end

    test "a surrogate pair the text cuts in half heals before the pair" do
      high = esc("d83d")
      backslash_u = <<?\\, ?u>>

      for cut <- [high, high <> "\\", high <> backslash_u, high <> backslash_u <> "de8"] do
        assert JsonReader.read_partial_items(~s([{"text": "Rocket ) <> cut, ["text"]) ==
                 [{%{"text" => "Rocket "}, false}],
               cut
      end

      assert JsonReader.read_partial_items(~s([{"text": "Rocket ) <> high <> esc("de80"), ["text"]) ==
               [{%{"text" => "Rocket 🚀"}, false}]

      assert JsonReader.read_partial_items(~s([{"text": "a) <> high <> "x", ["text"]) ==
               [{%{"text" => "a�x"}, false}]
    end

    test "an array under a whole-item key keeps only its finished items" do
      read = &JsonReader.read_partial_items(&1, ["text"], ["components"])
      kept = [{%{"components" => [%{"id" => "a"}]}, false}]

      assert read.(~s([{"components": [{"id": "a"}, {"id": "b", "text": "Hel)) == kept
      assert read.(~s([{"components": [{"id": "a"}, {"id)) == kept
      assert read.(~s([{"components": [{"id": "a"}, )) == kept

      assert read.(~s([{"components": [{"id": "a"}]}])) == [
               {%{"components" => [%{"id" => "a"}]}, true}
             ]

      assert read.(~s([{"components": [{"id": "a"}], "text": "x)) ==
               [{%{"components" => [%{"id" => "a"}], "text" => "x"}, false}]
    end

    test "a single message reads as a list of one" do
      assert JsonReader.read_partial_items(~s({"a": 1}), []) == [{%{"a" => 1}, true}]
      assert JsonReader.read_partial_items(~s({"a": "x), ["a"]) == [{%{"a" => "x"}, false}]
      assert JsonReader.read_partial_items(~s({"a), []) == []
    end

    test "curly quotes are straightened when the text does not read as it is" do
      assert JsonReader.read_partial_items(~s([{“a”: “b”}]), []) == [{%{"a" => "b"}, true}]
    end

    test "text that does not read gives no messages" do
      for text <- [
            ~s([{"a": 1}] trailing),
            ~s([{"a": 1} {"b": 2}]),
            ~s({"a": 1} trailing),
            ~s([{"a": x}]),
            ~s([{“a”: x}])
          ] do
        assert JsonReader.read_partial_items(text, []) == [], text
      end
    end
  end
end

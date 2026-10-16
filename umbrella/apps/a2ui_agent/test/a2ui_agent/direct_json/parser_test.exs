defmodule A2UIAgent.DirectJson.ParserTest do
  @moduledoc false
  use ExUnit.Case, async: true

  import A2UIAgent.Test.Fixtures

  alias A2UIAgent.DirectJson.Parser
  alias A2UICore.Error

  setup_all do
    {:ok, parser} = Parser.new([basic()], progressive_keys: ["text"])
    %{parser: parser}
  end

  defp block(messages), do: "<a2ui-json>" <> Jason.encode!(messages) <> "</a2ui-json>"

  # Feeds the chunks in turn and returns the parts each one produced.
  defp stream(parser, chunks, options \\ []) do
    {_parser, parts} =
      Enum.reduce(chunks, {parser, []}, fn chunk, {parser, acc} ->
        {:ok, parser, parts} = Parser.parse_chunk(parser, chunk, options)
        {parser, [parts | acc]}
      end)

    Enum.reverse(parts)
  end

  test "new/2 needs a usable list of catalogs" do
    assert {:error, %Error{category: :catalog}} = Parser.new([])
    assert {:ok, %Parser{progressive_keys: keys}} = Parser.new([basic()])
    assert keys == MapSet.new()
  end

  describe "unwrap/1 and wrap/1" do
    test "split text from blocks, dropping code fences around blocks" do
      content =
        "Intro\n<a2ui-json>\n[1]\n</a2ui-json>\nOutro\n" <>
          ~s(<A2UI-JSON data-x="1">```json\n[2]\n```</a2ui-json >)

      assert Parser.unwrap(content) == [
               {:text, "Intro"},
               {:a2ui_raw, "[1]", true},
               {:text, "Outro"},
               {:a2ui_raw, "[2]", true}
             ]

      assert Parser.unwrap("") == []
      assert Parser.unwrap("  \n ") == []
    end

    test "a block whose closing tag has not arrived is not final" do
      assert Parser.unwrap("Hi <a2ui-json>[1, 2") == [{:text, "Hi"}, {:a2ui_raw, "[1, 2", false}]
    end

    test "a closing tag inside a JSON string does not close the block" do
      raw = ~S([{"text": "</a2ui-json> \" still"}])
      assert Parser.unwrap("<a2ui-json>" <> raw <> "</a2ui-json>") == [{:a2ui_raw, raw, true}]
      assert Parser.unwrap("<a2ui-json>[1 <b> 2]</a2ui-json>") == [{:a2ui_raw, "[1 <b> 2]", true}]
    end

    test "wrap writes each block between tags" do
      assert Parser.wrap([{:text, "a"}, {:a2ui_raw, "[1]"}, {:a2ui_raw, "[2]", false}]) ==
               "a\n<a2ui-json>\n[1]\n</a2ui-json>\n<a2ui-json>\n[2]\n</a2ui-json>"
    end

    test "has_format_content?/2 finds a block, or with complete: true a closed one" do
      refute Parser.has_format_content?("plain text")
      assert Parser.has_format_content?("x <a2ui-json>[")
      refute Parser.has_format_content?("x <a2ui-json>[", complete: true)
      assert Parser.has_format_content?("x <a2ui-json>[]</a2ui-json>", complete: true)
    end
  end

  describe "compile/2" do
    test "a block compiles into validated messages; one message reads as a list", %{
      parser: parser
    } do
      assert Parser.compile(parser, Jason.encode!(surface())) == {:ok, surface()}

      assert Parser.compile(parser, "```json\n#{Jason.encode!(delete())}\n```") ==
               {:ok, [delete()]}
    end

    test "an empty or unreadable block is a parse error", %{parser: parser} do
      assert {:error, %Error{category: :parse, message: "The direct JSON block is empty."}} =
               Parser.compile(parser, " ``` ``` ")

      assert {:error, %Error{category: :parse, message: message}} = Parser.compile(parser, "[x]")

      assert message ==
               "The direct JSON block is not JSON: Invalid JSON at 1: unexpected character 'x'"
    end

    test "messages a renderer would reject are a validation error", %{parser: parser} do
      assert {:error, %Error{category: :validation}} =
               Parser.compile(
                 parser,
                 ~s([{"version": "v0.9", "deleteSurface": {"surfaceId": "s"}}])
               )
    end
  end

  test "decompile/1 writes pretty JSON and wrap_decompiled_blocks/1 encloses blocks" do
    assert Parser.decompile(%{"a" => 1}) == "[\n  {\n    \"a\": 1\n  }\n]"
    assert Parser.decompile([]) == "[]"
    assert Parser.wrap_decompiled_blocks(["[1]", "[2]"]) == "<a2ui-json>\n[1]\n[2]\n</a2ui-json>"
  end

  describe "parse_response/3" do
    test "compiles every block in order", %{parser: parser} do
      content = "Here it is.\n" <> block(surface()) <> "\nDone."

      assert Parser.parse_response(parser, content) ==
               {:ok, [{:text, "Here it is."}, {:a2ui, surface()}, {:text, "Done."}]}

      assert Parser.parse_response(parser, Jason.encode!(surface()), wrapped: false) ==
               {:ok, [{:a2ui, surface()}]}
    end

    test "stops at the first block that fails", %{parser: parser} do
      content = block(surface()) <> "<a2ui-json>[x]</a2ui-json><a2ui-json></a2ui-json>"

      assert {:error, %Error{category: :parse, message: "The direct JSON block is not JSON" <> _}} =
               Parser.parse_response(parser, content)

      assert {:error, %Error{category: :parse}} =
               Parser.parse_response(parser, "", wrapped: false)
    end
  end

  describe "parse_chunk/3" do
    test "emits text as it arrives and messages as they validate", %{parser: parser} do
      create = Jason.encode!(create())

      chunks = [
        "Hello ",
        "there <a2u",
        "i-json>[",
        create <> ",",
        ~s({"version": "v1.0", "updateComponents": {"surfaceId": "s1", "components": ) <>
          ~s([{"id": "root", "component": "Text", "text": "Hel),
        ~s(lo"}]}}),
        "]</a2ui-json> Bye"
      ]

      [_create, update] = surface()

      assert stream(parser, chunks) == [
               [{:text, "Hello"}],
               [{:text, " there"}],
               [],
               [{:a2ui, [create()]}],
               [],
               [{:a2ui, [update]}],
               [{:text, "Bye"}]
             ]
    end

    test "keeps whitespace inside a run of text, even across chunks", %{parser: parser} do
      assert stream(parser, ["Hello", " ", "world  ", "", "\n"]) ==
               [[{:text, "Hello"}], [], [{:text, " world"}], [], []]
    end

    test "holds back only what may start an open tag", %{parser: parser} do
      assert stream(parser, ["1 < 2 <A2", ~s(UI-JSON x="1">[]</a2ui-json>)]) ==
               [[{:text, "1 < 2"}], []]

      assert stream(parser, ["x <a2ui-json data", ~s(="1">), Jason.encode!([delete()])]) ==
               [[{:text, "x"}], [], [{:a2ui, [delete()]}]]
    end

    test "a create message waits until its object closes", %{parser: parser} do
      open =
        ~s(<a2ui-json>[{"version": "v1.0", "createSurface": {"surfaceId": "s1", ) <>
          ~s("catalogId": "#{basic_id()}")

      assert stream(parser, [open, "}}"]) == [[], [{:a2ui, [create()]}]]
    end

    test "a message that grows is emitted again" do
      {:ok, parser} = Parser.new([basic_v09()], progressive_keys: ["text"])
      id = basic_v09().catalog_id

      chunks = [
        "<a2ui-json>[" <> Jason.encode!(create("s1", id, "v0.9")) <> ",",
        ~s({"version": "v0.9", "updateComponents": {"surfaceId": "s1", "components": ) <>
          ~s([{"id": "root", "component": "Text", "text": "Hel),
        "lo",
        ~s("}]}}]</a2ui-json>)
      ]

      grown = fn value -> update([text("root", value)], "s1", "v0.9") end

      assert stream(parser, chunks) == [
               [{:a2ui, [create("s1", id, "v0.9")]}],
               [{:a2ui, [grown.("Hel")]}],
               [{:a2ui, [grown.("Hello")]}],
               []
             ]
    end

    test "drops code fences around a streamed block", %{parser: parser} do
      chunks = ["<a2ui-json>```js", "on\n[" <> Jason.encode!(delete()), "]\n``", "`</a2ui-json>"]
      assert stream(parser, chunks) == [[], [{:a2ui, [delete()]}], [], []]
    end

    test "reads up to a closing tag the chunk cuts off", %{parser: parser} do
      assert stream(parser, [block([delete()]) |> String.trim_trailing("json>"), "json>"]) ==
               [[{:a2ui, [delete()]}], []]

      assert stream(parser, ["<a2ui-json>" <> Jason.encode!([delete()]) <> "</a2ui-json ", ">"]) ==
               [[{:a2ui, [delete()]}], []]
    end

    test "stops at the first message that does not read or validate", %{parser: parser} do
      assert stream(parser, ["<a2ui-json>[1,"]) == [[]]

      {:ok, parser} = Parser.new([basic_v09()])
      bad = update([%{"id" => "root", "component" => "Nope"}], "s1", "v0.9")
      messages = [delete("s1", "v0.9"), bad, delete("s2", "v0.9")]

      assert stream(parser, ["<a2ui-json>" <> Jason.encode!(messages)]) ==
               [[{:a2ui, [delete("s1", "v0.9")]}]]
    end

    test "a v1.0 components update that does not validate is an error at once",
         %{parser: parser} do
      {:ok, parser, [{:a2ui, [_delete]}]} =
        Parser.parse_chunk(parser, "<a2ui-json>[" <> Jason.encode!(delete()) <> ",")

      {:ok, parser, []} =
        Parser.parse_chunk(
          parser,
          ~s({"version": "v1.0", "updateComponents": {"surfaceId": ) <>
            ~s("s1", "components": [{"id": "root", "component": "Nope")
        )

      assert {:error, %Error{category: :validation}} = Parser.parse_chunk(parser, "}")
    end

    test "tracks the catalog each streamed surface was created with" do
      a = catalog("a", ["Text"])
      b = catalog("b", ["Text", "Card"])
      {:ok, parser} = Parser.new([a, b])
      card = update([%{"id" => "root", "component" => "Card"}])

      assert {:error, %Error{category: :validation}} =
               Parser.parse_chunk(
                 parser,
                 "<a2ui-json>" <> Jason.encode!([create("s1", "a"), card])
               )

      messages = [create("s1", "a"), delete(), card]

      assert stream(parser, ["<a2ui-json>" <> Jason.encode!(messages)]) ==
               [[{:a2ui, messages}]]
    end

    test "a block that does not compile when it closes is an error", %{parser: parser} do
      {:ok, parser, []} = Parser.parse_chunk(parser, "<a2ui-json>[1")

      assert {:error, %Error{category: :validation, message: "Message 0 is not a JSON object."}} =
               Parser.parse_chunk(parser, "]</a2ui-json>")
    end

    test "without tags the whole response is one block", %{parser: parser} do
      json = Jason.encode!([delete(), delete("s2")])
      {first, second} = String.split_at(json, div(byte_size(json), 2) + 4)

      assert stream(parser, [first, second], wrapped: false) ==
               [[{:a2ui, [delete()]}], [{:a2ui, [delete("s2")]}]]
    end

    test "a response is either wrapped or not", %{parser: parser} do
      {:ok, parser, []} = Parser.parse_chunk(parser, "")

      assert_raise ArgumentError, ~r/either wrapped or not/, fn ->
        Parser.parse_chunk(parser, "[", wrapped: false)
      end
    end
  end

  test "clean/1 trims a block and drops one code fence" do
    assert Parser.clean("  ```json\n[1]\n```  ") == "[1]"
    assert Parser.clean("text") == "text"
  end
end

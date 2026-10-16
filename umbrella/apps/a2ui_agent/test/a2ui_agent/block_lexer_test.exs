defmodule A2UIAgent.BlockLexerTest do
  @moduledoc false
  use ExUnit.Case, async: true

  alias A2UIAgent.BlockLexer

  doctest BlockLexer

  test "text around blocks is trimmed, and empty text is left out" do
    assert BlockLexer.tokenize("  Hi\n<a2ui>\na = 1\n</a2ui>\n\n") ==
             [{:text, "Hi"}, {:a2ui_raw, "a = 1", true}]

    assert BlockLexer.tokenize("<a2ui></a2ui>") == [{:a2ui_raw, "", true}]
    assert BlockLexer.tokenize("just text") == [{:text, "just text"}]
    assert BlockLexer.tokenize("   ") == []
  end

  test "tags ignore case and the opening tag may carry attributes" do
    assert BlockLexer.tokenize(~s(<A2UI version="1">x = 1</A2UI >)) == [
             {:a2ui_raw, "x = 1", true}
           ]
  end

  test "a closing tag inside a string or a comment does not close the block" do
    content = ~s(<a2ui>a = "</a2ui>"\nb = 'x</a2ui>'\n# </a2ui>\nc = """</a2ui>"""</a2ui>)

    assert [{:a2ui_raw, raw, true}] = BlockLexer.tokenize(content)
    assert raw == ~s(a = "</a2ui>"\nb = 'x</a2ui>'\n# </a2ui>\nc = """</a2ui>""")
  end

  test "escapes inside strings are skipped, and line breaks end comments" do
    assert [{:a2ui_raw, ~S(a = "\"</a2ui>"), true}] =
             BlockLexer.tokenize(~S(<a2ui>a = "\"</a2ui>"</a2ui>))

    assert [{:a2ui_raw, "# c\r\nb = 1", true}] = BlockLexer.tokenize("<a2ui># c\r\nb = 1</a2ui>")
  end

  test "an unterminated block, string or comment is not final" do
    assert BlockLexer.tokenize("Hi <a2ui>a = 1") == [{:text, "Hi"}, {:a2ui_raw, "a = 1", false}]
    assert BlockLexer.tokenize(~s(<a2ui>a = "open)) == [{:a2ui_raw, ~s(a = "open), false}]
    assert BlockLexer.tokenize("<a2ui>a = 1 # note") == [{:a2ui_raw, "a = 1 # note", false}]
    assert BlockLexer.tokenize("<a2ui>a = \"\\") == [{:a2ui_raw, "a = \"\\", false}]
  end

  test "code fences around text and blocks are dropped" do
    content = "```text\nIntro\n```\n<a2ui>\n```express\nroot = Text(\"a\")\n```\n</a2ui>"

    assert BlockLexer.tokenize(content) == [
             {:text, "Intro"},
             {:a2ui_raw, ~s|root = Text("a")|, true}
           ]
  end

  test "the tag, string delimiters and comment markers are options" do
    options = [tag: "ui", string_delimiters: ["`"], comments: ["//"]]

    assert BlockLexer.tokenize("<ui>a = `</ui>` // </ui>\n</ui> after", options) ==
             [{:a2ui_raw, "a = `</ui>` // </ui>", true}, {:text, "after"}]
  end
end

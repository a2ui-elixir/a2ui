defmodule A2UIAgent.Express.ParserTest do
  @moduledoc false
  use ExUnit.Case, async: true

  import A2UIAgent.Test.Fixtures, only: [basic_id: 0]

  alias A2UIAgent.Express.Parser
  alias A2UICore.{Catalog, Error}

  setup_all do
    {:ok, parser} = Parser.new([Catalog.Basic.catalog("v1.0")], surface_id: "main")
    %{parser: parser}
  end

  test "new/2 checks the catalogs and the version" do
    assert {:error, %Error{category: :catalog}} = Parser.new([])

    assert {:error, %Error{category: :catalog, message: message}} =
             Parser.new([Catalog.Basic.catalog("v1.0")], version: "v0.9")

    assert message =~ "does not match catalog version 'v1.0'"

    assert {:ok, %Parser{surface_id: "main"}} =
             Parser.new([Catalog.Basic.catalog("v1.0")], version: "1.0")

    assert {:error, %Error{category: :catalog}} =
             Parser.new([Catalog.Basic.catalog("v1.0")], version: "nonsense")
  end

  test "unwrap/1, wrap/1 and has_format_content?/2" do
    content = "Hi\n<a2ui>\nroot = Text(\"a\")\n</a2ui>\nBye"
    parts = Parser.unwrap(content)
    assert parts == [{:text, "Hi"}, {:a2ui_raw, ~s|root = Text("a")|, true}, {:text, "Bye"}]
    assert Parser.wrap(parts) == content
    assert Parser.wrap([{:a2ui_raw, "x"}]) == "<a2ui>\nx\n</a2ui>"

    assert Parser.has_format_content?(content)
    assert Parser.has_format_content?("<a2ui>root = ")
    refute Parser.has_format_content?("<a2ui>root = ", complete: true)
    assert Parser.has_format_content?(content, complete: true)
    refute Parser.has_format_content?("no tags")
  end

  test "parse_response/3 compiles each block in place", %{parser: parser} do
    content = "Hello\n<a2ui>\nroot = Text(\"a\")\n</a2ui>\n<a2ui>deleteSurface(\"main\")</a2ui>"

    assert {:ok, [{:text, "Hello"}, {:a2ui, [create]}, {:a2ui, [delete]}]} =
             Parser.parse_response(parser, content)

    assert create["createSurface"]["surfaceId"] == "main"
    assert create["createSurface"]["catalogId"] == basic_id()
    assert delete == %{"version" => "v1.0", "deleteSurface" => %{"surfaceId" => "main"}}
  end

  test "parse_response/3 reads an unterminated block leniently", %{parser: parser} do
    assert {:ok, [{:a2ui, [%{"createSurface" => _}]}]} =
             Parser.parse_response(parser, "<a2ui>\nroot = Text(\"a\")\nb = Text(")
  end

  test "parse_response/3 compiles an unwrapped response whole and reports failures",
       %{parser: parser} do
    assert {:ok, [{:a2ui, [_]}]} =
             Parser.parse_response(parser, ~s|root = Text("a")|, wrapped: false)

    assert {:error, %Error{category: :validation}} =
             Parser.parse_response(parser, "<a2ui>root = Sparkline()</a2ui>")

    assert {:error, %Error{category: :validation}} =
             Parser.parse_response(parser, "root = Sparkline()", wrapped: false)
  end

  test "decompile/2 and wrap_decompiled_blocks/1", %{parser: parser} do
    assert {:ok, express} =
             Parser.decompile(parser, %{
               "version" => "v1.0",
               "deleteSurface" => %{"surfaceId" => "s"}
             })

    assert express == ~s|deleteSurface("s")|
    assert Parser.wrap_decompiled_blocks([express, "x"]) == "<a2ui>\n#{express}\nx\n</a2ui>"
    refute Parser.supports_streaming?()
  end
end

defmodule A2UIAgent.ExpressTest do
  @moduledoc false
  use ExUnit.Case, async: true

  alias A2UIAgent.Express
  alias A2UICore.{Catalog, Error}

  test "a format over its catalogs, with a parser and the pieces of its prompt" do
    catalog = Catalog.Basic.catalog("v1.0")

    assert {:ok, format} =
             Express.new([catalog],
               allowed_messages: ["deleteSurface"],
               surface_id: "s",
               examples: []
             )

    assert Express.catalogs(format) == [catalog]
    assert {:ok, prompt} = Express.prompt(format)
    assert prompt =~ "To delete a user interface surface"
    assert Express.base_rules(format) =~ "1. Primitives:"
    assert Express.catalog_instructions(format) =~ "• Button("
    assert Express.catalog_instructions(format, catalog.catalog_id) =~ "• Button("
    assert Express.examples(format) == {:ok, ""}

    parser = Express.parser(format)
    assert %Express.Parser{surface_id: "s"} = parser

    assert {:ok, [{:a2ui, [%{"createSurface" => %{"surfaceId" => "s"}}]}]} =
             Express.Parser.parse_response(parser, ~s|<a2ui>root = Text("a")</a2ui>|)

    assert {:ok, %Express{surface_id: "main"}} = Express.new([catalog])
    assert {:error, %Error{category: :catalog}} = Express.new([])
  end
end

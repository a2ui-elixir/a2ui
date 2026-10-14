defmodule A2UIAgent.DirectJsonTest do
  @moduledoc false
  use ExUnit.Case, async: true

  import A2UIAgent.Test.Fixtures

  alias A2UIAgent.{DirectJson, Format}
  alias A2UIAgent.DirectJson.{Parser, Prompt}
  alias A2UICore.Error

  doctest DirectJson

  test "Format.create/3 builds the format a spec names" do
    assert {:ok, %DirectJson{examples: nil, allowed_messages: nil, progressive_keys: []}} =
             Format.create(DirectJson, [basic()], nil)

    assert {:ok, %DirectJson{} = format} =
             Format.create(
               {DirectJson, allowed_messages: ["deleteSurface"], progressive_keys: ["text"]},
               [basic()],
               [surface()]
             )

    assert format.examples == [surface()]
    assert format.allowed_messages == ["deleteSurface"]
    assert format.progressive_keys == ["text"]
  end

  test "new/2 needs a usable list of catalogs" do
    assert {:error, %Error{category: :catalog}} = DirectJson.new([])
  end

  test "the format renders its prompt and creates parsers" do
    {:ok, format} =
      DirectJson.new([basic()],
        examples: [surface()],
        allowed_messages: ["deleteSurface"],
        progressive_keys: ["text"]
      )

    assert DirectJson.prompt(format) ==
             Prompt.generate([basic()],
               examples: [surface()],
               allowed_messages: ["deleteSurface"]
             )

    assert %Parser{progressive_keys: keys, catalogs: [catalog]} = DirectJson.parser(format)
    assert keys == MapSet.new(["text"])
    assert catalog.catalog_id == basic_id()
  end
end

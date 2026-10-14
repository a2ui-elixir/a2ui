defmodule A2UIAgent.RequestProcessorTest do
  @moduledoc false
  use ExUnit.Case, async: true

  import A2UIAgent.Test.Fixtures

  alias A2UIAgent.{DirectJson, RequestProcessor}
  alias A2UIAgent.DirectJson.Parser
  alias A2UIAgent.Test.EchoFormat
  alias A2UICore.Error

  test "needs at least one catalog, and examples that validate" do
    assert {:error,
            %Error{category: :catalog, message: "At least one active catalog is required."}} =
             RequestProcessor.new([])

    assert {:error, %Error{category: :validation, message: "Message 0 states no version" <> _}} =
             RequestProcessor.new([basic()], examples: [surface(), [%{"deleteSurface" => %{}}]])
  end

  test "binds the direct JSON format to the active catalogs by default" do
    assert {:ok, processor} = RequestProcessor.new([basic()], examples: [surface()])

    assert %RequestProcessor{format: %DirectJson{examples: [_turn]}} = processor
    assert [%{catalog_id: id}] = RequestProcessor.active_catalogs(processor)
    assert id == basic_id()
    assert {:ok, prompt} = RequestProcessor.prompt(processor)
    assert prompt =~ "### Examples:"
    assert %Parser{} = RequestProcessor.parser(processor)

    content = "Sure.\n<a2ui-json>" <> Jason.encode!(surface()) <> "</a2ui-json>"

    assert RequestProcessor.parse_response(processor, content) ==
             {:ok, [{:text, "Sure."}, {:a2ui, surface()}]}

    assert RequestProcessor.parse_response(processor, Jason.encode!(surface()), wrapped: false) ==
             {:ok, [{:a2ui, surface()}]}
  end

  test "uses the format a spec names" do
    assert {:ok, processor} =
             RequestProcessor.new([basic()], format: {EchoFormat, flavor: :plain})

    assert {:ok, "echo [examples: nil, flavor: :plain]"} = RequestProcessor.prompt(processor)
    assert %EchoFormat{} = RequestProcessor.parser(processor)

    assert RequestProcessor.parse_response(processor, "hi") == {:ok, [{:echo, "hi", []}]}
  end
end

defmodule A2UIAgent.ExamplesTest do
  @moduledoc false
  # Every upstream basic-catalog example bundle, written out the way a
  # model writes direct JSON and read back, whole and streamed. Generates
  # no bundle tests when the upstream checkout is absent;
  # `A2UI_REQUIRE_REFERENCE=1` makes that a failure.

  use ExUnit.Case, async: true

  alias A2UIAgent.DirectJson.Parser
  alias A2UIAgent.Test.Reference
  alias A2UICore.Catalog.Basic
  alias A2UICore.Error

  # A bundle that one payload may not send: once replaced, its loading
  # placeholders are unreachable, and its v1.0 component ids are not UAX
  # #31 identifiers. Python's `validate_payload` rejects it too.
  @not_one_payload ["31_incremental-dashboard.json"]

  bundles = Reference.bundle_files()

  if Reference.required?() do
    test "the reference examples were found" do
      assert length(unquote(Macro.escape(bundles))) == 86
    end
  end

  for {version, file} <- bundles do
    @external_resource file
    name = Path.basename(file)

    describe "#{version} #{name}" do
      if name in @not_one_payload do
        test "is not one valid payload" do
          {_messages, parser, response} = load(unquote(version), unquote(file))

          assert {:error, %Error{category: category}} = Parser.parse_response(parser, response)
          assert category in [:validation, :integrity]
        end
      else
        test "reads back whole" do
          {messages, parser, response} = load(unquote(version), unquote(file))

          assert Parser.parse_response(parser, response) ==
                   {:ok, [{:text, "Here it is."}, {:a2ui, messages}]}
        end

        test "reads back streamed" do
          {messages, parser, response} = load(unquote(version), unquote(file))
          emitted = stream(parser, response)

          assert for(message <- messages, message not in emitted, do: message) == []
        end
      end
    end
  end

  defp load(version, file) do
    messages = file |> File.read!() |> Jason.decode!() |> Map.fetch!("messages")
    {:ok, parser} = Parser.new([Basic.catalog(version)])
    response = "Here it is.\n" <> Parser.wrap_decompiled_blocks([Parser.decompile(messages)])
    {messages, parser, response}
  end

  # The messages emitted while the response streams in short chunks.
  defp stream(parser, response) do
    {_parser, emitted} =
      response
      |> String.graphemes()
      |> Enum.chunk_every(24)
      |> Enum.reduce({parser, []}, fn chunk, {parser, emitted} ->
        assert {:ok, parser, parts} = Parser.parse_chunk(parser, Enum.join(chunk))
        {parser, emitted ++ for({:a2ui, messages} <- parts, message <- messages, do: message)}
      end)

    emitted
  end
end

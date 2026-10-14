defmodule A2UIAgent.A2ATest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias A2UIAgent.A2A
  alias A2UIAgent.DirectJson.Parser
  alias A2UIAgent.Test.Fixtures

  @base "https://a2ui.org/a2a-extension/a2ui"
  @mime "application/a2ui+json"
  @deprecated_mime "application/json+a2ui"

  describe "mime_type" do
    test "is application/a2ui+json from v0.9.1 on" do
      assert A2A.mime_type() == @mime

      for version <- ["0.9.1", "v0.9.1", "1.0", "v1.0", "v1.2.0"],
          do: assert(A2A.mime_type(version) == @mime, version)
    end

    test "is the older type before v0.9.1 and for an unknown version" do
      for version <- [nil, "0.9", "v0.9", "0.9.0", "v0.5"],
          do: assert(A2A.mime_type(version) == @deprecated_mime, inspect(version))
    end

    test "is the current type for a version it cannot read" do
      assert A2A.mime_type("next") == @mime
    end
  end

  describe "extension URIs" do
    test "name the version after a v" do
      assert A2A.extension_base_uri() == @base
      assert A2A.extension_uri("1.0") == @base <> "/v1.0"
      assert A2A.extension_uri("v0.9.1") == @base <> "/v0.9.1"
    end

    test "give their version back" do
      assert A2A.extension_version(@base <> "/v1.0") == "1.0"
      assert A2A.extension_version(@base <> "/v") == nil
      assert A2A.extension_version("https://example.com/ext/v1.0") == nil
    end
  end

  describe "agent_extension" do
    test "has no params by default" do
      assert A2A.agent_extension("1.0") == %{
               "uri" => @base <> "/v1.0",
               "description" => "Provides agent driven UI using the A2UI JSON format."
             }
    end

    test "lists only the params that differ from their defaults" do
      assert A2A.agent_extension("1.0", accepts_inline_catalogs: true)["params"] == %{
               "acceptsInlineCatalogs" => true
             }

      assert A2A.agent_extension("1.0", supported_catalog_ids: ["a", "b"])["params"] == %{
               "supportedCatalogIds" => ["a", "b"]
             }

      assert A2A.agent_extension("1.0",
               accepts_inline_catalogs: false,
               supported_catalog_ids: []
             )
             |> Map.has_key?("params")
             |> Kernel.not()
    end
  end

  describe "negotiation" do
    test "an agent card advertises its A2UI extensions" do
      card = %{
        "capabilities" => %{
          "extensions" => [
            %{"uri" => @base <> "/v1.0"},
            %{"uri" => "https://example.com/other"},
            %{"uri" => @base <> "/v1.0"},
            %{"description" => "no uri"},
            %{"uri" => @base <> "/v0.9.1"}
          ]
        }
      }

      assert A2A.advertised_extensions(card) == [@base <> "/v1.0", @base <> "/v0.9.1"]
      assert A2A.advertised_extensions(%{"name" => "no capabilities"}) == []
    end

    test "a client requests extensions in header values and lists" do
      values = [
        "https://example.com/other, #{@base}/v1.0",
        " #{@base}/v0.9.1 ,#{@base}/v1.0",
        42
      ]

      assert A2A.requested_extensions(values) == [@base <> "/v1.0", @base <> "/v0.9.1"]
    end

    test "the newest extension both sides know is selected, by SemVer" do
      requested = Enum.map(["0.1.0", "1.2.0", "0.8.0", "1.10.0"], &A2A.extension_uri/1)
      advertised = Enum.map(["0.1.0", "1.2.0", "1.10.0", "2.0.0"], &A2A.extension_uri/1)

      assert A2A.select_newest(requested, advertised) == @base <> "/v1.10.0"
      assert A2A.select_newest(requested, []) == nil

      assert A2A.select_newest([@base <> "/v1.0", @base <> "/v1.0.1"], [@base <> "/v1.0.1"]) ==
               @base <> "/v1.0.1"
    end

    test "activation returns the extension and its version" do
      uri = @base <> "/v1.0"

      assert A2A.activate([uri], [uri]) == {:ok, uri, "1.0"}
      assert A2A.activate([], [uri]) == :none
      assert A2A.activate([uri], []) == :none
    end
  end

  describe "parts" do
    test "an A2UI part carries the data and the MIME type of its version" do
      message = Fixtures.delete()

      assert A2A.a2ui_part(message, "v1.0") == %{
               "kind" => "data",
               "data" => message,
               "metadata" => %{"mimeType" => @mime}
             }

      assert A2A.a2ui_part([message], nil)["metadata"]["mimeType"] == @deprecated_mime
      assert A2A.text_part("Hi") == %{"kind" => "text", "text" => "Hi"}
    end

    test "A2UI parts are data parts with either MIME type" do
      assert A2A.a2ui_part?(A2A.a2ui_part(%{}, "v1.0"))
      assert A2A.a2ui_part?(A2A.a2ui_part(%{}, "v0.9"))
      assert A2A.a2ui_part?(%{"data" => %{}, "metadata" => %{"mimeType" => @mime}})
      refute A2A.a2ui_part?(%{"data" => %{}, "metadata" => %{"mimeType" => "application/json"}})

      refute A2A.a2ui_part?(%{
               "kind" => "file",
               "data" => %{},
               "metadata" => %{"mimeType" => @mime}
             })

      refute A2A.a2ui_part?(%{"kind" => "data", "data" => %{}})
      refute A2A.a2ui_part?(A2A.text_part("Hi"))
      refute A2A.a2ui_part?("data")
    end

    test "the messages of A2UI parts are read in order, one or many per part" do
      [create, update] = Fixtures.surface()
      delete = Fixtures.delete()

      parts = [
        A2A.text_part("before"),
        A2A.a2ui_part(create, "v1.0"),
        %{"kind" => "data", "data" => %{"useStreaming" => false}},
        A2A.a2ui_part([update, "not a message"], "v1.0"),
        %{"kind" => "data", "data" => delete, "mimeType" => @mime}
      ]

      assert A2A.a2ui_messages(parts) == [create, update, delete]
    end

    test "parsed parts become text and data parts" do
      message = Fixtures.delete()

      assert A2A.to_parts([{:text, ""}, {:text, "Hi"}, {:a2ui, [message, message]}], "v1.0") == [
               A2A.text_part("Hi"),
               A2A.a2ui_part(message, "v1.0"),
               A2A.a2ui_part(message, "v1.0")
             ]
    end
  end

  describe "response_parts" do
    setup do
      {:ok, parser} = Parser.new([Fixtures.basic()])
      %{parser: parser}
    end

    test "parses a response into parts", %{parser: parser} do
      [create, update] = Fixtures.surface()
      response = "Here.\n<a2ui-json>#{Jason.encode!([create, update])}</a2ui-json>\nDone."

      assert A2A.response_parts(parser, response, "v1.0") == [
               A2A.text_part("Here."),
               A2A.a2ui_part(create, "v1.0"),
               A2A.a2ui_part(update, "v1.0"),
               A2A.text_part("Done.")
             ]
    end

    test "logs a response that does not parse and falls back to text", %{parser: parser} do
      response = "Oops <a2ui-json>[{ nope</a2ui-json>"

      log =
        capture_log(fn ->
          assert A2A.response_parts(parser, response, "v1.0", fallback_text: response) == [
                   A2A.text_part(response)
                 ]
        end)

      assert log =~ "Failed to parse A2UI response"

      capture_log(fn ->
        assert A2A.response_parts(parser, response, "v1.0") == []
        assert A2A.response_parts(parser, response, "v1.0", fallback_text: "") == []
      end)
    end

    test "falls back to text when a response has no parts", %{parser: parser} do
      assert A2A.response_parts(parser, "", "v1.0", fallback_text: "fallback") == [
               A2A.text_part("fallback")
             ]
    end
  end

  describe "chunk_parts" do
    test "reads chunks into parts" do
      {:ok, parser} = Parser.new([Fixtures.basic()])
      delete = Fixtures.delete()

      assert {:ok, parser, [text]} = A2A.chunk_parts(parser, "Hi <a2ui-json>", "v1.0")
      assert text == A2A.text_part("Hi")

      assert {:ok, _parser, [part]} =
               A2A.chunk_parts(parser, Jason.encode!([delete]) <> "</a2ui-json>", "v1.0")

      assert part == A2A.a2ui_part(delete, "v1.0")
    end

    test "returns the error of a chunk that does not parse" do
      {:ok, parser} = Parser.new([Fixtures.basic()])

      assert {:error, %A2UICore.Error{}} =
               A2A.chunk_parts(parser, "<a2ui-json>[{ nope</a2ui-json>", "v1.0")
    end
  end
end

defmodule A2UIAgent.CatalogProviderTest do
  @moduledoc false
  use ExUnit.Case, async: true

  alias A2UIAgent.CatalogProvider
  alias A2UICore.Error

  @document %{
    "catalogId" => "acme/basic",
    "protocolVersion" => "1.0",
    "components" => %{
      "Text" => %{
        "type" => "object",
        "properties" => %{"text" => %{"type" => "string"}},
        "required" => ["text"]
      }
    },
    "functions" => %{
      "required" => %{
        "type" => "object",
        "properties" => %{"call" => %{"const" => "required"}}
      }
    }
  }

  defp catalog_error!(result) do
    assert {:error, %Error{category: :catalog, message: message}} = result
    message
  end

  describe "load_document/2" do
    test "returns what the document declares" do
      assert {:ok, catalog} = CatalogProvider.load_document(@document)
      assert catalog.catalog_id == "acme/basic"
      assert catalog.protocol_version == "v1.0"
      assert Map.keys(catalog.components) == ["Text"]
      assert Map.keys(catalog.functions) == ["required"]
    end

    test "the options supply what the document omits" do
      document = Map.drop(@document, ["catalogId", "protocolVersion"])

      assert {:ok, catalog} =
               CatalogProvider.load_document(document,
                 catalog_id: "acme/provided",
                 protocol_version: "v0.9.1"
               )

      assert catalog.catalog_id == "acme/provided"
      assert catalog.protocol_version == "v0.9.1"
    end

    test "options that repeat the document are accepted" do
      assert {:ok, _catalog} =
               CatalogProvider.load_document(@document,
                 catalog_id: "acme/basic",
                 protocol_version: "v1.0"
               )
    end

    test "options that contradict the document are errors" do
      assert catalog_error!(CatalogProvider.load_document(@document, catalog_id: "other")) =~
               "declares catalog id 'acme/basic', but the provider was given 'other'"

      assert catalog_error!(CatalogProvider.load_document(@document, protocol_version: "v0.9")) =~
               "declares protocol version '1.0', but the provider was given 'v0.9'"
    end

    test "an id or a version that nothing states is an error" do
      without_id = Map.delete(@document, "catalogId")
      without_version = Map.delete(@document, "protocolVersion")

      assert catalog_error!(CatalogProvider.load_document(without_id)) =~ "nothing names"

      assert catalog_error!(CatalogProvider.load_document(without_version)) =~
               "nothing states which protocol"
    end

    test "malformed ids and versions are errors" do
      assert catalog_error!(CatalogProvider.load_document(@document, catalog_id: "")) =~
               "Provider 'catalog_id' must be a non-empty string."

      assert catalog_error!(CatalogProvider.load_document(%{@document | "catalogId" => 7})) =~
               "declares a 'catalogId' that is not a non-empty string"

      assert catalog_error!(CatalogProvider.load_document(@document, protocol_version: "v7")) =~
               "invalid protocol version"

      assert catalog_error!(CatalogProvider.load_document(%{@document | "protocolVersion" => ""})) =~
               "declares a 'protocolVersion' that is not a non-empty string"

      assert catalog_error!(
               CatalogProvider.load_document(%{@document | "protocolVersion" => "0.8"})
             ) =~ "declares unsupported protocol version '0.8'"
    end

    test "a document that is not a map is an error" do
      assert catalog_error!(CatalogProvider.load_document(["Text"])) =~ "is not a mapping"
    end

    test "the bang variant raises" do
      assert CatalogProvider.load_document!(@document).catalog_id == "acme/basic"

      assert_raise Error, ~r/nothing names/, fn ->
        CatalogProvider.load_document!(Map.delete(@document, "catalogId"))
      end
    end
  end

  describe "load_file/2" do
    @describetag :tmp_dir

    test "reads a path or a file:// URL", %{tmp_dir: dir} do
      path = Path.join(dir, "basic catalog.json")
      File.write!(path, Jason.encode!(@document))

      assert {:ok, catalog} = CatalogProvider.load_file(path)
      assert catalog.catalog_id == "acme/basic"

      url = "file://" <> URI.encode(path)
      assert CatalogProvider.load_file!(url).catalog_id == "acme/basic"
    end

    test "a missing file, malformed JSON and a non-object are errors", %{tmp_dir: dir} do
      assert catalog_error!(CatalogProvider.load_file(Path.join(dir, "absent.json"))) =~
               "Cannot read the catalog document"

      malformed = Path.join(dir, "malformed.json")
      File.write!(malformed, "{\"catalogId\": ")
      assert catalog_error!(CatalogProvider.load_file(malformed)) =~ "is not valid JSON"

      list = Path.join(dir, "list.json")
      File.write!(list, "[1, 2]")
      assert catalog_error!(CatalogProvider.load_file(list)) =~ "is not a JSON object"
    end

    test "a URL scheme other than file is an error; a drive letter is a path" do
      assert catalog_error!(CatalogProvider.load_file("https://example.com/c.json")) =~
               "Unsupported catalog URL scheme 'https'"

      assert catalog_error!(CatalogProvider.load_file("C:/catalogs/absent.json")) =~
               "Cannot read the catalog document 'C:/catalogs/absent.json'"
    end

    test "the bang variant raises" do
      assert_raise Error, ~r/Unsupported catalog URL scheme/, fn ->
        CatalogProvider.load_file!("ftp://example.com/c.json")
      end
    end
  end
end

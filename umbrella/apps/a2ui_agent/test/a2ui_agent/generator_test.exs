defmodule A2UIAgent.GeneratorTest do
  @moduledoc false
  use ExUnit.Case, async: true

  import A2UIAgent.Test.Fixtures

  alias A2UIAgent.{CatalogConfig, DirectJson, Generator, RequestProcessor}
  alias A2UIAgent.Test.EchoFormat
  alias A2UICore.Error

  setup_all do
    %{generator: Generator.new([CatalogConfig.new(basic())], examples: [surface()])}
  end

  defp supported(ids), do: %{"v1.0" => %{"supportedCatalogIds" => ids}}

  test "new/2 defaults to the direct JSON format and no inline catalogs" do
    assert %Generator{format: DirectJson, accepts_inline_catalogs: false, examples: nil} =
             Generator.new([])
  end

  test "creates a processor over the catalogs the renderer supports", %{generator: generator} do
    assert {:ok, %RequestProcessor{format: %DirectJson{}} = processor} =
             Generator.create_processor(generator, supported([basic_id()]))

    assert [%{catalog_id: id}] = processor.catalogs
    assert id == basic_id()
    assert processor.examples == [surface()]
  end

  test "the format can be overridden per processor", %{generator: generator} do
    assert {:ok, %RequestProcessor{format: %EchoFormat{}}} =
             Generator.create_processor(generator, supported([basic_id()]), format: EchoFormat)
  end

  test "capabilities are required and must name a registered catalog", %{generator: generator} do
    assert {:error,
            %Error{category: :catalog, message: "Renderer capabilities are required" <> _}} =
             Generator.create_processor(generator, nil)

    assert {:error, %Error{category: :catalog, message: "No client-supported catalog" <> _}} =
             Generator.create_processor(generator, supported(["other"]))
  end

  test "inline catalogs are used when the generator accepts them" do
    inline = %{
      "catalogId" => "inline",
      "components" => %{"Marquee" => %{"type" => "object", "properties" => %{}}}
    }

    capabilities = %{"v1.0" => %{"supportedCatalogIds" => [], "inlineCatalogs" => [inline]}}
    generator = Generator.new([CatalogConfig.new(basic())], accepts_inline_catalogs: true)

    assert {:ok, %RequestProcessor{catalogs: [%{catalog_id: "inline"}]}} =
             Generator.create_processor(generator, capabilities)
  end
end

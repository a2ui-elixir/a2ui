defmodule A2UIConformance.SurfaceStateTest do
  @moduledoc false
  use ExUnit.Case, async: true

  alias A2UIConformance.SurfaceState
  alias A2UICore.Catalog.Basic
  alias A2UICore.Processor
  alias A2UICore.State.Surface

  @catalog_id Basic.catalog("v0.9.1").catalog_id

  defp processor(messages) do
    processor = Processor.new([Basic.catalog("v0.9.1")])

    for message <- messages, reduce: processor do
      processor ->
        assert {:ok, processor, _effects} = Processor.process(processor, message)
        processor
    end
  end

  defp create(id, extra \\ %{}) do
    %{
      "version" => "v0.9",
      "createSurface" => Map.merge(%{"surfaceId" => id, "catalogId" => @catalog_id}, extra)
    }
  end

  defp components(id, list) do
    %{
      "version" => "v0.9",
      "updateComponents" => %{"surfaceId" => id, "components" => list}
    }
  end

  defp data(id, value) do
    %{"version" => "v0.9", "updateDataModel" => %{"surfaceId" => id, "value" => value}}
  end

  defp surface(messages), do: messages |> processor() |> Processor.surface("s")

  describe "resolve/1" do
    test "binds each component against the data model" do
      surface =
        surface([
          create("s"),
          data("s", %{"name" => "Ada"}),
          components("s", [
            %{"id" => "root", "component" => "Text", "text" => %{"path" => "/name"}}
          ])
        ])

      assert {%{"root" => %{type: "Text", props: %{"text" => "Ada"}}}, []} =
               SurfaceState.resolve(surface)
    end

    test "template items are keyed by index and by scoped path" do
      surface =
        surface([
          create("s"),
          data("s", %{"items" => [%{"label" => "a"}, %{"label" => "b"}]}),
          components("s", [
            %{
              "id" => "root",
              "component" => "List",
              "children" => %{"componentId" => "row", "path" => "/items"}
            },
            %{"id" => "row", "component" => "Text", "text" => %{"path" => "label"}}
          ])
        ])

      {nodes, _effects} = SurfaceState.resolve(surface)

      assert nodes["row_0"].props["text"] == "a"
      assert nodes["row_1"].props["text"] == "b"
      assert nodes["row-[/items/0]"].props["text"] == "a"
      assert nodes["row-[/items/1]"].props["text"] == "b"
      assert nodes["root"].type == "List"
    end

    test "children of an item are instantiated for that item" do
      surface =
        surface([
          create("s"),
          data("s", %{"items" => [%{"label" => "a"}]}),
          components("s", [
            %{
              "id" => "root",
              "component" => "List",
              "children" => %{"componentId" => "card", "path" => "/items"}
            },
            %{"id" => "card", "component" => "Card", "child" => "inner"},
            %{"id" => "inner", "component" => "Text", "text" => %{"path" => "label"}}
          ])
        ])

      {nodes, _effects} = SurfaceState.resolve(surface)

      assert nodes["inner_0"].props["text"] == "a"
      assert nodes["inner-[/items/0]"].props["text"] == "a"
    end

    test "a template over a non-list resolves nothing extra" do
      surface =
        surface([
          create("s"),
          data("s", %{"items" => "nope"}),
          components("s", [
            %{
              "id" => "root",
              "component" => "List",
              "children" => %{"componentId" => "row", "path" => "/items"}
            },
            %{"id" => "row", "component" => "Text", "text" => "x"}
          ])
        ])

      {nodes, _effects} = SurfaceState.resolve(surface)
      refute Map.has_key?(nodes, "row_0")
    end
  end

  describe "first_resolution_error/1" do
    test "is nil for a clean surface" do
      processor =
        processor([
          create("s"),
          components("s", [%{"id" => "root", "component" => "Text", "text" => "hi"}])
        ])

      assert SurfaceState.first_resolution_error(processor) == nil
    end

    test "reports a failing function call" do
      processor =
        processor([
          create("s"),
          components("s", [
            %{
              "id" => "root",
              "component" => "Text",
              "text" => %{"call" => "formatNumber", "args" => %{"value" => "not a number"}}
            }
          ])
        ])

      assert is_binary(SurfaceState.first_resolution_error(processor))
    end
  end

  describe "assert_state/2" do
    setup do
      processor =
        processor([
          create("s", %{"theme" => %{"primaryColor" => "#00AAFF"}, "sendDataModel" => true}),
          data("s", %{"n" => 1}),
          components("s", [
            %{"id" => "root", "component" => "Column", "children" => ["t"]},
            %{"id" => "t", "component" => "Text", "text" => %{"path" => "/n"}}
          ])
        ])

      {:ok, processor: processor}
    end

    defp expect(processor, surfaces),
      do: SurfaceState.assert_state(processor, %{"surfaces" => surfaces})

    test "a matching expectation passes", %{processor: processor} do
      assert :ok =
               expect(processor, %{
                 "s" => %{
                   "exists" => true,
                   "theme" => %{"primaryColor" => "#00AAFF"},
                   "sendDataModel" => true,
                   "dataModel" => %{"n" => 1},
                   "components" => %{"t" => %{"component" => "Text", "text" => "1"}}
                 }
               })
    end

    test "components may be listed; a list pins the count", %{processor: processor} do
      listed = [
        %{"id" => "root", "component" => "Column"},
        %{"id" => "t", "component" => "Text", "text" => 1}
      ]

      assert :ok = expect(processor, %{"s" => %{"components" => listed}})

      assert_raise ExUnit.AssertionError, ~r/component count mismatch/, fn ->
        expect(processor, %{"s" => %{"components" => [hd(listed)]}})
      end
    end

    test "an absent surface", %{processor: processor} do
      assert :ok = expect(processor, %{"gone" => %{"exists" => false}})

      assert_raise ExUnit.AssertionError, ~r/should not exist/, fn ->
        expect(processor, %{"s" => %{"exists" => false}})
      end

      assert_raise ExUnit.AssertionError, ~r/does not exist/, fn ->
        expect(processor, %{"gone" => %{"exists" => true}})
      end
    end

    test "mismatches raise", %{processor: processor} do
      assert_raise ExUnit.AssertionError, fn ->
        expect(processor, %{"s" => %{"theme" => %{"primaryColor" => "#000000"}}})
      end

      assert_raise ExUnit.AssertionError, fn ->
        expect(processor, %{"s" => %{"sendDataModel" => false}})
      end

      assert_raise ExUnit.AssertionError, fn ->
        expect(processor, %{"s" => %{"dataModel" => %{"n" => 2}}})
      end

      assert_raise ExUnit.AssertionError, ~r/property 'text' mismatch/, fn ->
        expect(processor, %{"s" => %{"components" => %{"t" => %{"text" => "2"}}}})
      end

      assert_raise ExUnit.AssertionError, ~r/missing from surface/, fn ->
        expect(processor, %{"s" => %{"components" => %{"zzz" => %{"component" => "Text"}}}})
      end

      assert_raise ExUnit.AssertionError, ~r/is a Text/, fn ->
        expect(processor, %{"s" => %{"components" => %{"t" => %{"component" => "Button"}}}})
      end
    end

    test "validation results are read from the bound component" do
      check = %{"condition" => false, "message" => "no"}

      processor =
        processor([
          create("s"),
          components("s", [
            %{
              "id" => "root",
              "component" => "TextField",
              "label" => "L",
              "value" => "",
              "checks" => [check]
            }
          ])
        ])

      assert :ok =
               expect(processor, %{
                 "s" => %{
                   "validationResult" => %{"root" => %{"valid" => false, "message" => "no"}}
                 }
               })

      assert_raise ExUnit.AssertionError, fn ->
        expect(processor, %{"s" => %{"validationResult" => %{"root" => %{"valid" => true}}}})
      end

      assert_raise ExUnit.AssertionError, ~r/component node 'zzz' missing/, fn ->
        expect(processor, %{"s" => %{"validationResult" => %{"zzz" => %{"valid" => true}}}})
      end
    end

    test "an expectation without surfaces asserts nothing", %{processor: processor} do
      assert :ok = SurfaceState.assert_state(processor, %{})
      assert :ok = SurfaceState.assert_state(processor, nil)
    end
  end

  test "the processor's surface is a Surface" do
    assert %Surface{id: "s"} = surface([create("s")])
  end
end

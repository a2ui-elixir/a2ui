defmodule A2UICore.State.SurfaceTest do
  @moduledoc false
  use ExUnit.Case, async: true

  alias A2UICore.Catalog.Basic
  alias A2UICore.State.{Component, Components, DataModel, Surface, SurfaceGroup}

  doctest A2UICore.State.Surface
  doctest A2UICore.State.SurfaceGroup

  @now ~U[2026-03-04 05:06:07Z]

  describe "Surface.default_catalog/1" do
    test "is the catalog registered under the surface's catalog id" do
      catalog = Basic.catalog("v1.0")

      surface =
        Surface.new("s",
          catalog_id: catalog.catalog_id,
          catalogs: %{catalog.catalog_id => catalog}
        )

      assert Surface.default_catalog(surface) == catalog
    end

    test "is nil without one" do
      assert Surface.default_catalog(Surface.new("s")) == nil
      assert Surface.default_catalog(Surface.new("s", catalog_id: "urn:missing")) == nil
    end
  end

  describe "Surface.new/2" do
    test "defaults" do
      surface = Surface.new("main")

      assert surface.id == "main"
      assert surface.root_id == "root"
      assert surface.catalog_id == nil
      assert surface.theme == %{}
      assert surface.send_data_model == false
      assert surface.metadata == %{}
      assert DataModel.data(surface.data_model) == %{}
      assert Components.size(surface.components) == 0
    end

    test "options" do
      surface =
        Surface.new("s",
          catalog_id: "cat",
          catalogs: %{"cat" => :catalog},
          theme: %{"primaryColor" => "#fff"},
          send_data_model: true,
          root_id: "main",
          version: "v1.0",
          data_model: %{"a" => 1},
          metadata: %{"host" => 1}
        )

      assert surface.catalog_id == "cat"
      assert surface.catalogs == %{"cat" => :catalog}
      assert surface.theme == %{"primaryColor" => "#fff"}
      assert surface.send_data_model
      assert surface.root_id == "main"
      assert surface.version == "v1.0"
      assert surface.metadata == %{"host" => 1}
      assert DataModel.data(surface.data_model) == %{"a" => 1}
    end

    test "accepts an existing data model" do
      model = DataModel.new(%{"x" => 1})
      assert Surface.new("s", data_model: model).data_model == model
    end

    test "a nil theme becomes empty" do
      assert Surface.new("s", theme: nil).theme == %{}
    end
  end

  describe "data access" do
    test "set_data and get_data" do
      surface = Surface.new("s")

      assert {:ok, surface, []} = Surface.set_data(surface, "/user/name", "Ada")
      assert Surface.get_data(surface, "/user/name") == {:ok, "Ada"}
    end

    test "set_data returns notifications for subscribers" do
      surface = Surface.new("s")
      {:ok, model, id, nil} = DataModel.subscribe(surface.data_model, "/a")
      surface = %{surface | data_model: model}

      assert {:ok, _surface, [{^id, "/a", 1}]} = Surface.set_data(surface, "/a", 1)
    end

    test "errors pass through" do
      assert {:error, %A2UICore.Error{category: :data}} =
               Surface.set_data(Surface.new("s"), "/__proto__", 1)

      assert {:error, %A2UICore.Error{category: :data}} =
               Surface.get_data(Surface.new("s"), "/__proto__")
    end

    test "put_components replaces the set" do
      set = Components.from_list([Component.new("root", "Text")])
      surface = Surface.put_components(Surface.new("s"), set)

      assert Components.ids(surface.components) == ["root"]
    end

    test "dispose detaches subscriptions" do
      surface = Surface.new("s")
      {:ok, model, _id, _} = DataModel.subscribe(surface.data_model, "/a")
      surface = Surface.dispose(%{surface | data_model: model})

      assert DataModel.subscriptions(surface.data_model) == []
    end
  end

  describe "dispatch_action/4" do
    setup do
      %{surface: Surface.new("main")}
    end

    test "builds the event from a plain action", %{surface: surface} do
      action = %{"name" => "submit", "context" => %{"id" => 7}}

      assert Surface.dispatch_action(surface, action, "btn", @now) == %{
               "name" => "submit",
               "surfaceId" => "main",
               "sourceComponentId" => "btn",
               "timestamp" => "2026-03-04T05:06:07Z",
               "context" => %{"id" => 7}
             }
    end

    test "unwraps an event object", %{surface: surface} do
      payload = %{"event" => %{"name" => "go", "context" => %{"k" => "v"}}}
      event = Surface.dispatch_action(surface, payload, "b", @now)

      assert event["name"] == "go"
      assert event["context"] == %{"k" => "v"}
    end

    test "carries catalogId from the payload or the event", %{surface: surface} do
      from_payload = %{"catalogId" => "c1", "event" => %{"name" => "go"}}
      from_event = %{"event" => %{"name" => "go", "catalogId" => "c2"}}
      both = %{"catalogId" => "c1", "event" => %{"name" => "go", "catalogId" => "c2"}}

      assert Surface.dispatch_action(surface, from_payload, "b", @now)["catalogId"] == "c1"
      assert Surface.dispatch_action(surface, from_event, "b", @now)["catalogId"] == "c2"
      assert Surface.dispatch_action(surface, both, "b", @now)["catalogId"] == "c1"
    end

    test "carries userMessage when present", %{surface: surface} do
      event =
        Surface.dispatch_action(surface, %{"name" => "go", "userMessage" => "hello"}, "b", @now)

      assert event["userMessage"] == "hello"

      refute Map.has_key?(
               Surface.dispatch_action(surface, %{"name" => "go"}, "b", @now),
               "userMessage"
             )
    end

    test "a non-object context becomes empty", %{surface: surface} do
      for context <- ["text", 5, nil, [1]] do
        event =
          Surface.dispatch_action(surface, %{"name" => "go", "context" => context}, "b", @now)

        assert event["context"] == %{}
      end
    end

    test "fractional seconds are kept; other zones are shifted to UTC", %{surface: surface} do
      with_micros = ~U[2026-03-04 05:06:07.250000Z]

      assert Surface.dispatch_action(surface, %{"name" => "g"}, "b", with_micros)["timestamp"] ==
               "2026-03-04T05:06:07.250000Z"

      shifted = %DateTime{
        year: 2026,
        month: 3,
        day: 4,
        hour: 6,
        minute: 6,
        second: 7,
        microsecond: {0, 0},
        time_zone: "Etc/GMT-1",
        zone_abbr: "+01",
        utc_offset: 3600,
        std_offset: 0
      }

      assert Surface.dispatch_action(surface, %{"name" => "g"}, "b", shifted)["timestamp"] ==
               "2026-03-04T05:06:07Z"
    end

    test "uses the current time by default", %{surface: surface} do
      event = Surface.dispatch_action(surface, %{"name" => "go"}, "b")
      assert {:ok, %DateTime{}, 0} = DateTime.from_iso8601(event["timestamp"])
    end

    test "returns nil when there is no usable action", %{surface: surface} do
      assert Surface.dispatch_action(surface, %{}, "b", @now) == nil
      assert Surface.dispatch_action(surface, %{"name" => ""}, "b", @now) == nil
      assert Surface.dispatch_action(surface, %{"name" => 5}, "b", @now) == nil
      assert Surface.dispatch_action(surface, %{"event" => "no"}, "b", @now) == nil
      assert Surface.dispatch_action(surface, %{"functionCall" => %{}}, "b", @now) == nil
      assert Surface.dispatch_action(surface, "go", "b", @now) == nil
      assert Surface.dispatch_action(surface, nil, "b", @now) == nil
    end
  end

  describe "SurfaceGroup" do
    test "add creates and reports the effect" do
      {group, effects} = SurfaceGroup.add(SurfaceGroup.new(), Surface.new("a"))

      assert effects == [{:surface_created, "a"}]
      assert SurfaceGroup.has?(group, "a")
      assert SurfaceGroup.get(group, "a").id == "a"
    end

    test "adding an existing id is a no-op" do
      {group, _} = SurfaceGroup.add(SurfaceGroup.new(), Surface.new("a", theme: %{"x" => 1}))
      {same, effects} = SurfaceGroup.add(group, Surface.new("a", theme: %{"x" => 2}))

      assert effects == []
      assert same == group
      assert SurfaceGroup.get(same, "a").theme == %{"x" => 1}
    end

    test "update replaces known surfaces only" do
      {group, _} = SurfaceGroup.add(SurfaceGroup.new(), Surface.new("a"))
      group = SurfaceGroup.update(group, %{Surface.new("a") | root_id: "main"})
      assert SurfaceGroup.get(group, "a").root_id == "main"

      assert SurfaceGroup.update(group, Surface.new("zzz")) == group
    end

    test "delete removes, disposes and reports" do
      {group, _} = SurfaceGroup.add(SurfaceGroup.new(), Surface.new("a"))

      assert {group, [{:surface_deleted, "a"}]} = SurfaceGroup.delete(group, "a")
      refute SurfaceGroup.has?(group, "a")
      assert SurfaceGroup.get(group, "a") == nil
    end

    test "deleting an unknown id is a no-op" do
      group = SurfaceGroup.new()
      assert {^group, []} = SurfaceGroup.delete(group, "nope")
    end

    test "ids and to_list are sorted" do
      group =
        Enum.reduce(["c", "a", "b"], SurfaceGroup.new(), fn id, group ->
          {group, _} = SurfaceGroup.add(group, Surface.new(id))
          group
        end)

      assert SurfaceGroup.ids(group) == ["a", "b", "c"]
      assert Enum.map(SurfaceGroup.to_list(group), & &1.id) == ["a", "b", "c"]
    end

    test "dispose deletes everything in id order" do
      group =
        Enum.reduce(["b", "a"], SurfaceGroup.new(), fn id, group ->
          {group, _} = SurfaceGroup.add(group, Surface.new(id))
          group
        end)

      assert {group, effects} = SurfaceGroup.dispose(group)
      assert effects == [{:surface_deleted, "a"}, {:surface_deleted, "b"}]
      assert SurfaceGroup.ids(group) == []
    end
  end
end

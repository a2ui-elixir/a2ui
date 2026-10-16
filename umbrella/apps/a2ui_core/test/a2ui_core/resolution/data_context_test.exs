defmodule A2UICore.Resolution.DataContextTest do
  @moduledoc false
  use ExUnit.Case, async: true

  alias A2UICore.Resolution.DataContext

  doctest A2UICore.Resolution.DataContext

  describe "new/1" do
    test "defaults to the root scope" do
      assert DataContext.new().path == "/"
    end

    test "always ends with a slash" do
      assert DataContext.new("/user").path == "/user/"
      assert DataContext.new("/user/").path == "/user/"
    end
  end

  describe "nested/3" do
    test "joins the relative path and ignores a leading slash" do
      root = DataContext.new()

      assert DataContext.nested(root, "items/2").path == "/items/2/"
      assert DataContext.nested(root, "/items/2").path == "/items/2/"
    end

    test "scopes stack" do
      scope = DataContext.new() |> DataContext.nested("items/2") |> DataContext.nested("tags/0")
      assert scope.path == "/items/2/tags/0/"
    end

    test "keeps the parent and an explicit index" do
      root = DataContext.new()
      child = DataContext.nested(root, "items", 4)

      assert child.parent == root
      assert child.index == 4
    end
  end

  describe "index/1" do
    test "an explicit index wins" do
      scope = DataContext.new() |> DataContext.nested("items/9", 2)
      assert DataContext.index(scope) == 2
    end

    test "falls back to the numeric last segment" do
      scope = DataContext.new() |> DataContext.nested("items/7")
      assert DataContext.index(scope) == 7
    end

    test "walks outward through non-numeric scopes" do
      scope =
        DataContext.new()
        |> DataContext.nested("items/3")
        |> DataContext.nested("meta")

      assert DataContext.index(scope) == 3
    end

    test "is nil outside a collection" do
      assert DataContext.index(DataContext.new()) == nil
      assert DataContext.index(DataContext.new("/user")) == nil
    end
  end

  describe "resolve_path/2" do
    test "absolute paths are returned unchanged" do
      scope = DataContext.new("/items/1")
      assert DataContext.resolve_path(scope, "/other/path") == "/other/path"
    end

    test "relative paths join the scope" do
      scope = DataContext.new("/items/1")
      assert DataContext.resolve_path(scope, "name") == "/items/1/name"
      assert DataContext.resolve_path(scope, "a/b") == "/items/1/a/b"
    end

    test "empty and dot resolve to the scope itself" do
      scope = DataContext.new("/items/1")
      assert DataContext.resolve_path(scope, "") == "/items/1"
      assert DataContext.resolve_path(scope, ".") == "/items/1"
    end

    test "the root scope" do
      root = DataContext.new()
      assert DataContext.resolve_path(root, "name") == "/name"
      assert DataContext.resolve_path(root, "") == "/"
      assert DataContext.resolve_path(root, ".") == "/"
    end
  end

  describe "agent functions" do
    alias A2UICore.Catalog
    alias A2UICore.Catalog.Basic
    alias A2UICore.State.DataModel

    @shop "https://example.com/catalogs/shop.json"

    defp shop do
      Catalog.from_json!(%{
        "catalogId" => @shop,
        "protocolVersion" => "v1.0",
        "components" => %{},
        "functions" => %{
          "inStock" => %{
            "type" => "object",
            "returnType" => "boolean",
            "properties" => %{
              "@call" => %{"const" => "inStock"},
              "args" => %{
                "type" => "object",
                "properties" => %{"sku" => %{"type" => "string"}},
                "required" => ["sku"]
              }
            },
            "required" => ["@call", "args"]
          }
        }
      })
    end

    defp scope(agent_calls, version \\ "v1.0") do
      basic = Basic.catalog(version)

      DataContext.new("/",
        catalog: basic,
        catalogs: %{basic.catalog_id => basic, @shop => shop()},
        data_model: DataModel.new(%{"zip" => "10115"}),
        agent_calls: agent_calls
      )
    end

    @lookup %{"@call" => "lookupCity", "args" => %{"zip" => %{"@path" => "/zip"}}}
    @key {"lookupCity", nil, %{"zip" => "10115"}}

    test "an undeclared function is routed: nil until the agent answers" do
      assert DataContext.resolve_dynamic_value(scope(%{}), @lookup) ==
               {nil,
                [
                  {:agent_call,
                   %{key: @key, call: %{"@call" => "lookupCity", "args" => %{"zip" => "10115"}}}}
                ]}

      assert {nil, [{:agent_call, _request}]} =
               DataContext.resolve_dynamic_value(scope(%{@key => :pending}), @lookup)

      assert {"Berlin", [{:agent_call, %{key: @key}}]} =
               DataContext.resolve_dynamic_value(scope(%{@key => {:ok, "Berlin"}}), @lookup)

      assert {nil, [{:agent_call, %{key: @key}}]} =
               DataContext.resolve_dynamic_value(
                 scope(%{@key => {:error, %{code: "TIMEOUT"}}}),
                 @lookup
               )
    end

    test "a function declared without an implementation is routed with its catalog" do
      call = %{"@call" => "inStock", "catalogId" => @shop, "args" => %{"sku" => "A-1"}}

      assert {nil, [{:agent_call, %{key: {"inStock", @shop, %{"sku" => "A-1"}}, call: ^call}}]} =
               DataContext.resolve_dynamic_value(scope(%{}), call)

      assert {nil, []} = DataContext.resolve_dynamic_value(scope(nil), call)

      assert {nil, [{:error, %{code: "EXPRESSION_ERROR"}}]} =
               DataContext.resolve_dynamic_value(scope(%{}), %{call | "args" => %{}})
    end

    test "without routing, or before v1.0, an undeclared function is an error" do
      assert {nil, [{:error, %{code: "EXPRESSION_ERROR"}}]} =
               DataContext.resolve_dynamic_value(scope(nil), @lookup)

      assert {nil, [{:error, %{code: "EXPRESSION_ERROR"}}]} =
               DataContext.resolve_dynamic_value(
                 scope(%{}, "v0.9.1"),
                 %{"call" => "lookupCity", "args" => %{}}
               )
    end

    test "a missing catalog is still a catalog error" do
      call = %{"@call" => "lookupCity", "catalogId" => "https://example.com/none.json"}

      assert {nil, [{:error, %{code: "CATALOG_ERROR"}}]} =
               DataContext.resolve_dynamic_value(scope(%{}), call)
    end

    test "an action's call is always routed; the calls in its arguments are looked up" do
      action = %{
        "functionCall" => %{
          "@call" => "reserve",
          "args" => %{
            "city" => @lookup,
            "label" => %{"@call" => "formatString", "args" => %{"value" => "Table"}}
          }
        }
      }

      calls = %{@key => {:ok, "Berlin"}}

      assert {nil, [{:agent_call, %{key: @key}}, {:agent_call, reserve}]} =
               DataContext.resolve_action(scope({:send, calls}), action)

      assert reserve == %{
               key: {"reserve", nil, %{"city" => "Berlin", "label" => "Table"}},
               call: %{"@call" => "reserve", "args" => %{"city" => "Berlin", "label" => "Table"}},
               action: true
             }

      event = %{"event" => %{"name" => "go", "context" => %{"city" => @lookup}}}

      assert {%{"event" => %{"context" => %{"city" => "Berlin"}}}, [{:agent_call, request}]} =
               DataContext.resolve_action(scope({:send, calls}), event)

      refute Map.has_key?(request, :action)

      assert {%{"context" => %{"city" => "Berlin"}}, [_lookup]} =
               DataContext.resolve_action(scope({:send, calls}), %{
                 "name" => "go",
                 "context" => %{"city" => @lookup}
               })
    end
  end

  describe "who may call" do
    alias A2UICore.Catalog
    alias A2UICore.Catalog.Basic
    alias A2UICore.State.DataModel

    @device "https://example.com/catalogs/device.json"

    defp device do
      Catalog.from_json!(%{
        "catalogId" => @device,
        "protocolVersion" => "v1.0",
        "components" => %{},
        "functions" => %{
          "deviceInfo" => %{
            "type" => "object",
            "returnType" => "object",
            "allowedCallers" => "agentOnly",
            "properties" => %{
              "@call" => %{"const" => "deviceInfo"},
              "args" => %{"type" => "object"}
            },
            "required" => ["@call"]
          }
        }
      })
      |> Catalog.put_implementations(%{
        "deviceInfo" => fn _args, _ctx -> {:ok, %{"os" => "test"}} end
      })
    end

    defp device_scope(options \\ []) do
      basic = Basic.catalog("v1.0")

      DataContext.new(
        "/",
        [
          catalog: basic,
          catalogs: %{basic.catalog_id => basic, @device => device()},
          data_model: DataModel.new(%{})
        ] ++ options
      )
    end

    @open %{"@call" => "openUrl", "args" => %{"url" => "https://a2ui.org"}}

    test "a function that needs a user gesture is refused outside one" do
      assert {nil, [{:error, %{code: "EXPRESSION_ERROR", message: message}}]} =
               DataContext.resolve_dynamic_value(device_scope(), @open)

      assert message == "Function 'openUrl' requires user activation context to execute."

      assert DataContext.resolve_dynamic_value(device_scope(user_activated: true), @open) ==
               {nil, []}
    end

    test "a function reserved for the agent is refused, gesture or not" do
      call = %{"@call" => "deviceInfo", "catalogId" => @device, "args" => %{}}

      for options <- [[], [user_activated: true]] do
        assert {nil, [{:error, %{code: "EXPRESSION_ERROR", message: message}}]} =
                 DataContext.resolve_dynamic_value(device_scope(options), call)

        assert message =~ "cannot be called by renderer (allowedCallers is agentOnly)"
      end
    end

    test "for_surface/2 and nested scopes keep the flag" do
      scope = device_scope(user_activated: true)
      assert DataContext.nested(scope, "items/0", 0).user_activated
      refute device_scope().user_activated
    end
  end
end

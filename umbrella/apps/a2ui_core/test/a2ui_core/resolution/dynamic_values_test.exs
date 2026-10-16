defmodule A2UICore.Resolution.DynamicValuesTest do
  @moduledoc false
  use ExUnit.Case, async: true

  alias A2UICore.Catalog
  alias A2UICore.Catalog.Basic
  alias A2UICore.Error
  alias A2UICore.Resolution.DataContext
  alias A2UICore.State.DataModel
  alias A2UICore.State.Surface

  @data %{
    "user" => %{"name" => "Ada", "age" => 36},
    "items" => [%{"name" => "first"}, %{"name" => "second"}],
    "flag" => true
  }

  setup_all do
    echo = %{
      "type" => "object",
      "properties" => %{
        "call" => %{"const" => "echo"},
        "args" => %{"type" => "object"}
      },
      "required" => ["call"]
    }

    echo_v10 = %{
      "type" => "object",
      "properties" => %{"@call" => %{"const" => "echo"}, "args" => %{"type" => "object"}},
      "required" => ["@call"]
    }

    implementations = %{"echo" => fn args, _ctx -> {:ok, %{"echoed" => args}} end}

    other =
      %{"catalogId" => "urn:test:other", "functions" => %{"echo" => echo}}
      |> Catalog.from_json!(protocol_version: "v0.9")
      |> Catalog.put_implementations(implementations)

    other_v10 =
      %{"catalogId" => "urn:test:other", "functions" => %{"echo" => echo_v10}}
      |> Catalog.from_json!(protocol_version: "v1.0")
      |> Catalog.put_implementations(implementations)

    {:ok, other: other, other_v10: other_v10}
  end

  defp context(version, data \\ @data, options \\ []) do
    DataContext.new(
      "/",
      Keyword.merge([data_model: DataModel.new(data), catalog: Basic.catalog(version)], options)
    )
  end

  describe "literals" do
    test "pass through unchanged" do
      ctx = context("v0.9")

      for value <- ["text", 4, 1.5, true, false, nil] do
        assert DataContext.resolve_dynamic_value(ctx, value) == {value, []}
      end
    end

    test "lists resolve element by element" do
      ctx = context("v0.9")
      value = [1, %{"path" => "/user/name"}, [%{"path" => "/flag"}]]

      assert DataContext.resolve_dynamic_value(ctx, value) == {[1, "Ada", [true]], []}
    end

    test "plain objects resolve their values" do
      ctx = context("v0.9")
      value = %{"label" => %{"path" => "/user/name"}, "n" => 1}

      assert DataContext.resolve_dynamic_value(ctx, value) == {%{"label" => "Ada", "n" => 1}, []}
    end
  end

  describe "bindings" do
    test "absolute paths read the data model" do
      ctx = context("v0.9")
      assert DataContext.resolve_dynamic_value(ctx, %{"path" => "/user/age"}) == {36, []}
    end

    test "relative paths resolve against the scope" do
      ctx = context("v0.9") |> DataContext.nested("items/1")

      assert DataContext.resolve_dynamic_value(ctx, %{"path" => "name"}) == {"second", []}

      assert DataContext.resolve_dynamic_value(ctx, %{"path" => "."}) ==
               {%{"name" => "second"}, []}
    end

    test "v1.0 uses @path" do
      ctx = context("v1.0")

      assert DataContext.resolve_dynamic_value(ctx, %{"@path" => "/user/name"}) == {"Ada", []}
      # `path` is an ordinary key in v1.0.
      assert {%{"path" => "/user/name"}, []} =
               DataContext.resolve_dynamic_value(ctx, %{"path" => "/user/name"})
    end

    test "a missing path is nil with a warning" do
      ctx = context("v0.9")

      assert {nil, [{:warning, warning}]} =
               DataContext.resolve_dynamic_value(ctx, %{"path" => "/user/email"})

      assert warning.code == "MISSING_DATA_BINDING"
      assert warning.path == "/user/email"
      assert warning.message =~ "'/user/email' does not physically exist"
    end

    test "an explicit null is present: no warning" do
      ctx = context("v0.9", %{"x" => nil})
      assert DataContext.resolve_dynamic_value(ctx, %{"path" => "/x"}) == {nil, []}
    end

    test "warnings are reported once per path" do
      ctx = context("v0.9")
      value = [%{"path" => "/gone"}, %{"path" => "/gone"}, %{"path" => "/other"}]

      assert {[nil, nil, nil], warnings} = DataContext.resolve_dynamic_value(ctx, value)
      assert Enum.map(warnings, fn {:warning, %{path: path}} -> path end) == ["/gone", "/other"]
    end

    test "without a data model a binding is nil" do
      ctx = DataContext.new("/", catalog: Basic.catalog("v0.9"))
      assert DataContext.resolve_dynamic_value(ctx, %{"path" => "/a"}) == {nil, []}
    end

    test "forbidden path segments are expression errors" do
      ctx = context("v0.9")

      assert {nil, [{:error, error}]} =
               DataContext.resolve_dynamic_value(ctx, %{"path" => "/__proto__/x"})

      assert error.code == "EXPRESSION_ERROR"
    end

    test "an object with componentId is not a binding" do
      ctx = context("v0.9")
      value = %{"componentId" => "row", "path" => "/items"}

      assert {%{"componentId" => "row", "path" => "/items"}, []} =
               DataContext.resolve_dynamic_value(ctx, value)
    end
  end

  describe "function calls" do
    test "v0.9 calls resolve their arguments first" do
      ctx = context("v0.9")

      call = %{
        "call" => "formatString",
        "args" => %{"value" => "Hello ${/user/name}"}
      }

      assert DataContext.resolve_dynamic_value(ctx, call) == {"Hello Ada", []}

      nested = %{
        "call" => "and",
        "args" => %{"values" => [%{"path" => "/flag"}, true]}
      }

      assert DataContext.resolve_dynamic_value(ctx, nested) == {true, []}
    end

    test "v1.0 calls use @call" do
      ctx = context("v1.0")

      call = %{
        "@call" => "formatNumber",
        "args" => %{"value" => %{"@path" => "/user/age"}, "decimals" => 1}
      }

      assert DataContext.resolve_dynamic_value(ctx, call) == {"36.0", []}
    end

    test "@index reads the collection scope" do
      ctx = context("v1.0") |> DataContext.nested("items/1")

      assert DataContext.resolve_dynamic_value(ctx, %{"@call" => "@index", "args" => %{}}) ==
               {1, []}
    end

    test "@index outside a collection is an expression error" do
      ctx = context("v1.0")

      assert {nil, [{:error, error}]} =
               DataContext.resolve_dynamic_value(ctx, %{"@call" => "@index", "args" => %{}})

      assert error.code == "EXPRESSION_ERROR"
      assert error.expression == "@index"
      assert error.message =~ "collection template iteration scope"
    end

    test "failures become error effects with a nil value" do
      ctx = context("v0.9")
      call = %{"call" => "openUrl", "args" => %{"url" => "javascript:alert(1)"}}

      assert {nil, [{:error, error}]} = DataContext.resolve_dynamic_value(ctx, call)
      assert error.message == "Unsupported URL scheme: javascript"
      assert error.expression == "openUrl"
    end

    test "unknown functions are expression errors" do
      ctx = context("v0.9")

      assert {nil, [{:error, error}]} =
               DataContext.resolve_dynamic_value(ctx, %{"call" => "nope", "args" => %{}})

      assert error.message =~ "Unrecognized function 'nope'"
    end

    test "invalid arguments are expression errors with details" do
      ctx = context("v0.9")

      assert {nil, [{:error, error}]} =
               DataContext.resolve_dynamic_value(ctx, %{"call" => "formatNumber", "args" => %{}})

      assert error.message =~ "'value' is a required property"
      assert [%{code: "missing_field"}] = error.details
    end

    test "without a default catalog a call that names none cannot run" do
      ctx = DataContext.new("/", data_model: DataModel.new(@data))

      assert {nil, [{:error, error}]} =
               DataContext.resolve_dynamic_value(ctx, %{"call" => "x", "args" => %{}})

      assert error.message ==
               "Function call 'x' names no catalogId and the context has no default catalog."

      ctx = DataContext.new("/", data_model: DataModel.new(@data), surface_id: "s1")

      assert {nil, [{:error, error}]} =
               DataContext.resolve_dynamic_value(ctx, %{"call" => "x", "args" => %{}})

      assert error.message ==
               "Function call 'x' names no catalogId and surface s1 has no default catalogId."
    end

    test "too many arguments" do
      ctx = context("v0.9")
      args = Map.new(1..1_001, &{"a#{&1}", 1})

      assert {nil, [{:error, error}]} =
               DataContext.resolve_dynamic_value(ctx, %{"call" => "formatNumber", "args" => args})

      assert error.message ==
               "Function call 'formatNumber' exceeds maximum allowed arguments count (1000)"
    end

    test "warnings from arguments are kept next to the result" do
      ctx = context("v0.9")
      call = %{"call" => "formatString", "args" => %{"value" => "${/missing}!"}}

      assert {"!", [{:warning, %{path: "/missing"}}]} =
               DataContext.resolve_dynamic_value(ctx, call)
    end

    test "from v1.0 catalogId selects another catalog", %{other_v10: other} do
      ctx = context("v1.0", @data, catalogs: %{"urn:test:other" => other})

      call = %{
        "@call" => "echo",
        "catalogId" => "urn:test:other",
        "args" => %{"who" => %{"@path" => "/user/name"}}
      }

      assert DataContext.resolve_dynamic_value(ctx, call) ==
               {%{"echoed" => %{"who" => "Ada"}}, []}
    end

    test "before v1.0 a call runs in the default catalog whatever catalogId it names",
         %{other: other} do
      ctx = context("v0.9", @data, catalogs: %{"urn:test:other" => other})
      call = %{"call" => "echo", "catalogId" => "urn:test:other", "args" => %{}}

      assert {nil, [{:error, error}]} = DataContext.resolve_dynamic_value(ctx, call)
      assert error.message =~ "Unrecognized function 'echo'"
    end

    test "from v1.0 an unknown catalogId is an error" do
      ctx = context("v1.0")
      call = %{"@call" => "echo", "catalogId" => "urn:missing", "args" => %{}}

      assert {nil, [{:error, error}]} = DataContext.resolve_dynamic_value(ctx, call)
      assert error.message == "Catalog not found: urn:missing"
      assert error.code == "CATALOG_ERROR"
    end

    test "a function declared without an implementation yields nil" do
      declared =
        Catalog.from_json!(
          %{
            "catalogId" => "urn:test:schema-only",
            "functions" => %{
              "ghost" => %{
                "type" => "object",
                "properties" => %{
                  "call" => %{"const" => "ghost"},
                  "args" => %{"type" => "object"}
                },
                "required" => ["call"]
              }
            }
          },
          protocol_version: "v0.9"
        )

      ctx = DataContext.new("/", data_model: DataModel.new(%{}), catalog: declared)

      assert DataContext.resolve_dynamic_value(ctx, %{"call" => "ghost", "args" => %{}}) ==
               {nil, []}
    end
  end

  describe "v1.0 reserved keys" do
    test "@@ escapes a literal @ key" do
      ctx = context("v1.0")
      value = %{"@@note" => %{"@path" => "/user/name"}}

      assert DataContext.resolve_dynamic_value(ctx, value) == {%{"@note" => "Ada"}, []}
    end

    test "an unknown @ directive is an error" do
      ctx = context("v1.0")

      assert {nil, [{:error, error}]} = DataContext.resolve_dynamic_value(ctx, %{"@bogus" => 1})
      assert error.message =~ "Unrecognized reserved protocol directive '@bogus'"
    end

    test "v0.9 has no reserved keys" do
      ctx = context("v0.9")
      assert DataContext.resolve_dynamic_value(ctx, %{"@bogus" => 1}) == {%{"@bogus" => 1}, []}
    end
  end

  describe "resolve_action/2" do
    test "resolves the context and user message of an event action" do
      ctx = context("v0.9")

      action = %{
        "event" => %{
          "name" => "submit",
          "context" => %{"who" => %{"path" => "/user/name"}, "n" => 1},
          "userMessage" => %{"path" => "/user/age"}
        }
      }

      assert DataContext.resolve_action(ctx, action) ==
               {%{
                  "event" => %{
                    "name" => "submit",
                    "context" => %{"who" => "Ada", "n" => 1},
                    "userMessage" => 36
                  }
                }, []}
    end

    test "an event without context resolves to an empty one" do
      ctx = context("v0.9")
      {resolved, []} = DataContext.resolve_action(ctx, %{"event" => %{"name" => "go"}})

      assert resolved == %{"event" => %{"name" => "go"}}
    end

    test "a non-object context becomes empty" do
      ctx = context("v0.9")

      {resolved, []} =
        DataContext.resolve_action(ctx, %{"event" => %{"name" => "go", "context" => "x"}})

      assert resolved["event"]["context"] == %{}
    end

    test "a named action is resolved in place" do
      ctx = context("v0.9")

      {resolved, []} =
        DataContext.resolve_action(ctx, %{
          "name" => "go",
          "context" => %{"a" => %{"path" => "/flag"}}
        })

      assert resolved == %{"name" => "go", "context" => %{"a" => true}}
    end

    test "function-call actions are evaluated" do
      ctx = context("v0.9")
      call = %{"call" => "formatString", "args" => %{"value" => "${/user/name}"}}

      assert DataContext.resolve_action(ctx, %{"functionCall" => call}) == {"Ada", []}
      assert DataContext.resolve_action(ctx, call) == {"Ada", []}
    end

    test "anything else is returned unchanged" do
      ctx = context("v0.9")

      assert DataContext.resolve_action(ctx, %{"other" => 1}) == {%{"other" => 1}, []}
      assert DataContext.resolve_action(ctx, "text") == {"text", []}
    end
  end

  describe "for_surface/2" do
    test "takes the data model and catalogs from the surface" do
      catalog = Basic.catalog("v0.9")

      surface =
        Surface.new("s",
          catalog_id: catalog.catalog_id,
          catalogs: %{catalog.catalog_id => catalog},
          data_model: %{"x" => 1},
          metadata: %{locale: "fr-FR"}
        )

      ctx = DataContext.for_surface(surface)

      assert ctx.catalog == catalog
      assert ctx.locale == "fr-FR"
      assert DataContext.resolve_dynamic_value(ctx, %{"path" => "/x"}) == {1, []}
      assert DataContext.for_surface(surface, path: "/sub", locale: "de-DE").locale == "de-DE"
    end
  end

  describe "v1?/1" do
    test "follows the default catalog" do
      assert DataContext.v1?(context("v1.0"))
      refute DataContext.v1?(context("v0.9"))
      refute DataContext.v1?(DataContext.new())
    end
  end

  describe "errors from implementations" do
    test "are reported as error effects" do
      failing =
        Catalog.from_json!(
          %{
            "catalogId" => "urn:test:failing",
            "functions" => %{
              "boom" => %{
                "type" => "object",
                "properties" => %{"call" => %{"const" => "boom"}, "args" => %{"type" => "object"}},
                "required" => ["call"]
              }
            }
          },
          protocol_version: "v0.9"
        )
        |> Catalog.put_implementations(%{
          "boom" => fn _args, _ctx ->
            {:error, Error.new(:expression, "EXPRESSION_ERROR", "kaboom")}
          end
        })

      ctx = DataContext.new("/", data_model: DataModel.new(%{}), catalog: failing)

      assert {nil, [{:error, %{message: "kaboom", expression: "boom"}}]} =
               DataContext.resolve_dynamic_value(ctx, %{"call" => "boom", "args" => %{}})
    end
  end
end

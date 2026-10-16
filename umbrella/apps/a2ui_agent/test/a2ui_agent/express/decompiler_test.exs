defmodule A2UIAgent.Express.DecompilerTest do
  @moduledoc false
  use ExUnit.Case, async: true

  import A2UIAgent.Test.Fixtures, only: [basic_id: 0, catalog: 2]

  alias A2UIAgent.Express.{Catalogs, Compiler, Decompiler}
  alias A2UICore.{Catalog, Error}

  doctest Decompiler

  setup_all do
    {:ok, v1} = Catalogs.new([Catalog.Basic.catalog("v1.0")])
    {:ok, v09} = Catalogs.new([Catalog.Basic.catalog("v0.9.1")])
    %{v1: v1, v09: v09}
  end

  defp decompile!(catalogs, messages) do
    assert {:ok, express} = Decompiler.decompile(catalogs, messages)
    express
  end

  defp round_trip!(catalogs, source) do
    assert {:ok, messages} = Compiler.compile(catalogs, source, surface_id: "s1")
    express = decompile!(catalogs, messages)
    assert {:ok, ^messages} = Compiler.compile(catalogs, express, surface_id: "s1")
    express
  end

  defp create(components, extra \\ %{}) do
    %{
      "version" => "v1.0",
      "createSurface" =>
        Map.merge(
          %{"surfaceId" => "s1", "catalogId" => basic_id(), "components" => components},
          extra
        )
    }
  end

  describe "surfaces" do
    test "a created surface is written in full, data before components", %{v1: v1} do
      messages = [
        create(
          [%{"id" => "root", "component" => "Text", "text" => %{"@path" => "/user/name"}}],
          %{
            "dataModel" => %{"user" => %{"name" => "Ada", "tags" => ["a"]}, "n" => 1.5},
            "sendDataModel" => true
          }
        )
      ]

      assert decompile!(v1, messages) ==
               """
               surface("s1", sendDataModel=true)
               $/n = 1.5
               $/user/name = "Ada"
               $/user/tags = ["a"]
               root = Text($/user/name)\
               """
    end

    test "the default surface at the start needs no surface line", %{v1: v1} do
      messages = [
        %{
          "version" => "v1.0",
          "createSurface" => %{
            "surfaceId" => "default_surface",
            "components" => [%{"id" => "root", "component" => "Text", "text" => "a"}]
          }
        }
      ]

      assert decompile!(v1, messages) == ~s|root = Text("a")|
    end

    test "split messages coalesce into the create", %{v1: v1} do
      messages = [
        %{
          "version" => "v1.0",
          "createSurface" => %{"surfaceId" => "s1", "catalogId" => basic_id()}
        },
        %{
          "version" => "v1.0",
          "updateComponents" => %{
            "surfaceId" => "s1",
            "components" => [%{"id" => "root", "component" => "Text", "text" => "a"}]
          }
        },
        %{
          "version" => "v1.0",
          "updateDataModel" => %{"surfaceId" => "s1", "value" => %{"a" => 1}}
        },
        %{
          "version" => "v1.0",
          "updateComponents" => %{
            "surfaceId" => "s1",
            "components" => [%{"id" => "more", "component" => "Text", "text" => "b"}]
          }
        }
      ]

      assert decompile!(v1, messages) ==
               ~s|surface("s1")\n$/a = 1\nroot = Text("a")\nsurface("s1")\nmore = Text("b")|
    end

    test "updates stay updates", %{v1: v1} do
      update = fn components ->
        %{
          "version" => "v1.0",
          "updateComponents" => %{"surfaceId" => "s2", "components" => components}
        }
      end

      assert decompile!(v1, [update.([%{"id" => "root", "component" => "Text", "text" => "a"}])]) ==
               ~s|surface("s2", update=true)\nroot = Text("a")|

      assert decompile!(v1, [
               %{
                 "version" => "v1.0",
                 "updateComponents" => %{
                   "surfaceId" => "default_surface",
                   "components" => [%{"id" => "x", "component" => "Text", "text" => "a"}]
                 }
               }
             ]) == ~s|x = Text("a")|
    end

    test "data updates: leaves of a map, a value at a path", %{v1: v1} do
      data = fn path, value ->
        body = %{"surfaceId" => "s1", "value" => value}
        body = if path, do: Map.put(body, "path", path), else: body
        [%{"version" => "v1.0", "updateDataModel" => body}]
      end

      assert decompile!(v1, data.("/", %{"a" => %{"b" => 1}})) == ~s|surface("s1")\n$/a/b = 1|

      assert decompile!(v1, data.("/user/", %{"name" => "Ada"})) ==
               ~s|surface("s1")\n$/user/name = "Ada"|

      assert decompile!(v1, data.("/n", 3)) == ~s|surface("s1")\n$/n = 3|
      assert decompile!(v1, data.(nil, %{})) == ~s|surface("s1")\n$/ = {}|
      assert decompile!(v1, data.("rel", nil)) == ~s|surface("s1")\n$rel = null|
    end

    test "deletes and other messages keep their place", %{v1: v1} do
      messages = [
        create([%{"id" => "root", "component" => "Text", "text" => "a"}]),
        %{"version" => "v1.0", "deleteSurface" => %{"surfaceId" => "s1"}},
        %{},
        %{"version" => "v1.0", "somethingElse" => %{}}
      ]

      assert decompile!(v1, messages) ==
               ~s|surface("s1")\nroot = Text("a")\ndeleteSurface("s1")\nsurface("default_surface")|
    end

    test "a surface naming an unknown catalog is an error", %{v1: v1} do
      messages = [create([], %{"catalogId" => "urn:nope"})]

      assert {:error, %Error{category: :validation, message: message}} =
               Decompiler.decompile(v1, messages)

      assert message =~ "Unknown catalog 'urn:nope'"
    end
  end

  describe "components" do
    test "positional arguments, placeholders and references", %{v1: v1} do
      assert round_trip!(
               v1,
               ~s|root = Column([a, b], _, "center")\na = Text("x")\nb = Image("u", _, "cover")|
             ) ==
               ~s|surface("s1")\nroot = Column([a, b], _, "center")\na = Text("x")\nb = Image("u", _, "cover")|
    end

    test "ids that are not identifiers get variables", %{v1: v1} do
      messages = [
        create([
          %{"id" => "root", "component" => "Card", "child" => "main-col"},
          %{"id" => "main-col", "component" => "Column", "children" => ["main_col", "true"]},
          %{"id" => "main_col", "component" => "Text", "text" => "a"},
          %{"id" => "true", "component" => "Text", "text" => "b"}
        ])
      ]

      express = decompile!(v1, messages)

      assert express ==
               """
               surface("s1")
               root = Card(main_col_2)
               main_col_2 = Column([main_col, _true], id="main-col")
               main_col = Text("a")
               _true = Text("b", id="true")\
               """

      assert {:ok, ^messages} = Compiler.compile(v1, express)
    end

    test "references to components outside the block", %{v1: v1} do
      messages = [
        create([
          %{"id" => "root", "component" => "Column", "children" => ["elsewhere", "far-away", 7]}
        ])
      ]

      assert decompile!(v1, messages) =~ ~s|root = Column([elsewhere, "far-away", 7])|
    end

    test "an unknown component or a component without a catalog is an error", %{v1: v1} do
      assert {:error, %Error{message: message}} =
               Decompiler.decompile(v1, [create([%{"id" => "root", "component" => "Sparkline"}])])

      assert message =~ "Unknown component 'Sparkline' not defined in catalog '#{basic_id()}'."
    end
  end

  describe "checks" do
    test "an implicit value, custom messages and lists of checks round trip", %{v1: v1} do
      source =
        ~s|root = TextField("N", $/n, checks=[?required, ?regex("^a", "Starts with a"), ?length(_, 3)])|

      assert round_trip!(v1, source) ==
               ~s|surface("s1")\nroot = TextField("N", $/n, [?required, ?regex("^a", "Starts with a"), ?length(_, 3)])|

      assert round_trip!(v1, ~s|root = TextField("N", $/n, ?email($/other))|) =~ "?email($/other)"
    end

    test "a rule without its condition wrapper is its own condition", %{v1: v1} do
      field = %{
        "id" => "root",
        "component" => "TextField",
        "label" => "N",
        "value" => %{"@path" => "/n"},
        "checks" => [%{"@call" => "required", "args" => %{"value" => %{"@path" => "/other"}}}]
      }

      assert decompile!(v1, [create([field])]) =~ "?required($/other)"
    end

    test "a condition that is not a call cannot be written", %{v1: v1} do
      field = %{
        "id" => "root",
        "component" => "TextField",
        "label" => "N",
        "checks" => [%{"condition" => true, "message" => "x"}]
      }

      assert {:error, %Error{message: message}} = Decompiler.decompile(v1, [create([field])])
      assert message =~ "condition is not a function call: true"
    end

    test "an empty check list is a placeholder", %{v1: v1} do
      field = %{"id" => "root", "component" => "TextField", "label" => "N", "checks" => []}
      assert decompile!(v1, [create([field])]) =~ ~s|root = TextField("N")|
    end
  end

  describe "values" do
    test "events, function calls, templates and maps", %{v1: v1} do
      source = """
      root = Row([a, b, c, d])
      a = Button(Text("x"), action=Event("go", {userId: "u1", "two words": true}))
      b = Button(Text("y"), action=Event("plain"))
      c = Button(Text("z"), action=Event("empty", {}))
      d = List(_template($/items, row))
      row = Text(formatNumber($value, 2))
      """

      express = round_trip!(v1, source)
      assert express =~ ~s|Event("go", {"two words": true, userId: "u1"})|
      assert express =~ ~s|Event("plain")|
      assert express =~ ~s|Event("empty", {})|
      assert express =~ "_template($/items, row)"
      assert express =~ "formatNumber($value, 2)"
      refute express =~ "action="
    end

    test "function calls in actions and arguments given as a list", %{v1: v1} do
      button = %{
        "id" => "root",
        "component" => "Button",
        "child" => "t",
        "action" => %{"functionCall" => %{"@call" => "openUrl", "args" => ["https://x.test"]}}
      }

      assert decompile!(v1, [
               create([button, %{"id" => "t", "component" => "Text", "text" => "go"}])
             ]) =~
               ~s|root = Button(t, _, openUrl("https://x.test"))|
    end

    test "strings take the most readable literal" do
      assert Decompiler.string("plain") == ~s|"plain"|
      assert Decompiler.string("a\nb") == ~s|"""a\nb"""|
      assert Decompiler.string("a\\b\nc") == ~s|r"""a\\b\nc"""|
      assert Decompiler.string("tab\there\nnext") == ~s|"""tab\\there\nnext"""|
      assert Decompiler.string("ends \"\n with quote\"") == ~S|"ends \"\n with quote\""|
      assert Decompiler.string("a\\\"b") == ~S|"a\\\"b"|
      assert Decompiler.string("cr\r") == ~S|"""cr| <> "\r" <> ~S|"""|
    end

    test "numbers are written as Python writes them" do
      assert Decompiler.number(3) == "3"
      assert Decompiler.number(0.0) == "0.0"
      assert Decompiler.number(-1.5e-7) == "-1.5e-07"
      assert Decompiler.number(2.5e20) == "2.5e+20"
      assert Decompiler.number(0.001) == "0.001"
      assert Decompiler.number(12.0) == "12.0"
    end

    test "map keys and event contexts keep the order of an ordered message", %{v1: v1} do
      json =
        ~s|[{"version": "v1.0", "createSurface": {"surfaceId": "s1", "catalogId": "#{basic_id()}", "components": [{"id": "root", "component": "Button", "child": "t", "action": {"event": {"name": "e", "context": {"z": 1, "a": {"k2": 2, "k1": 1}}}}}, {"id": "t", "component": "Text", "text": "x"}]}}]|

      messages = Jason.decode!(json, objects: :ordered_objects)
      assert decompile!(v1, messages) =~ ~s|Event("e", {z: 1, a: {k2: 2, k1: 1}})|
    end

    test "other values", %{v1: v1} do
      text = fn value -> [create([%{"id" => "root", "component" => "Text", "text" => value}])] end

      assert decompile!(v1, text.(nil)) =~ "root = Text(null)"
      assert decompile!(v1, text.(false)) =~ "root = Text(false)"
      assert decompile!(v1, text.([1, "a"])) =~ ~s|root = Text([1, "a"])|
      assert decompile!(v1, text.({:odd})) =~ ~s|root = Text("{:odd}")|
    end
  end

  describe "renderer calls" do
    test "call ids that the compiler would give are left out", %{v1: v1} do
      call = fn id ->
        %{
          "version" => "v1.0",
          "callRendererFunction" => %{
            "functionCallId" => id,
            "callFunction" => %{"@call" => "openUrl", "args" => %{"url" => "u"}}
          }
        }
      end

      assert decompile!(v1, [call.("call_1"), call.("mine")]) ==
               ~s|openUrl("u")\nopenUrl("u", functionCallId="mine")|

      top_level = %{"version" => "v1.0", "callFunction" => %{"@call" => "openUrl", "args" => %{}}}
      assert decompile!(v1, [top_level]) == "openUrl()"

      no_args = %{
        "version" => "v1.0",
        "callRendererFunction" => %{
          "functionCallId" => "x",
          "callFunction" => %{"@call" => "openUrl"}
        }
      }

      assert decompile!(v1, [no_args]) == ~s|openUrl(functionCallId="x")|

      assert {:error, _} =
               Decompiler.decompile(v1, [%{"callRendererFunction" => %{"callFunction" => 1}}])
    end
  end

  describe "several catalogs" do
    setup do
      {:ok, catalogs} =
        Catalogs.new([catalog("urn:a", ["Text", "Badge"]), catalog("urn:b", ["Text"])])

      %{multi: catalogs}
    end

    test "a catalog is named only where a name is shared", %{multi: multi} do
      messages = [
        %{
          "version" => "v1.0",
          "createSurface" => %{
            "surfaceId" => "s1",
            "components" => [
              %{"id" => "root", "component" => "Badge", "catalogId" => "urn:a"},
              %{"id" => "t", "component" => "Text", "catalogId" => "urn:b"}
            ]
          }
        }
      ]

      assert decompile!(multi, messages) ==
               ~s|surface("s1")\nroot = Badge()\nt = Text(catalogId="urn:b")|

      assert {:ok, ^messages} = Compiler.compile(multi, decompile!(multi, messages))
    end

    test "a component without a catalog on a surface without one is an error", %{multi: multi} do
      messages = [
        %{
          "version" => "v1.0",
          "createSurface" => %{
            "surfaceId" => "s1",
            "components" => [%{"id" => "root", "component" => "Badge"}]
          }
        }
      ]

      assert {:error, %Error{message: message}} = Decompiler.decompile(multi, messages)
      assert message =~ "Component 'Badge' names no catalogId, and its surface has no catalog."
    end
  end

  describe "unusual messages" do
    test "a check whose first parameter is not value, and odd values", %{v1: v1} do
      field = %{
        "id" => "root",
        "component" => "TextField",
        "label" => %{"path" => 1},
        "value" => %{"@path" => "/n"},
        "placeholder" => %{"path" => "/items", "componentId" => 3},
        "checks" => [%{"condition" => %{"@call" => "and", "args" => %{"values" => [true]}}}]
      }

      assert decompile!(v1, [create([field])]) =~
               ~s|root = TextField($1, $/n, _template($/items, "3"), ?and([true]))|
    end

    test "an event that is not an object, and a data model that is not one", %{v1: v1} do
      button = %{
        "id" => "root",
        "component" => "Button",
        "child" => "t",
        "action" => %{"event" => "x"}
      }

      assert decompile!(v1, [create([button], %{"dataModel" => 5})]) =~
               ~s|surface("s1")\n$ = 5\nroot = Button(t, _, Event(""))|
    end

    test "split ordered messages coalesce too", %{v1: v1} do
      json =
        ~s|[{"version": "v1.0", "createSurface": {"surfaceId": "s1", "catalogId": "#{basic_id()}"}}, | <>
          ~s|{"version": "v1.0", "updateComponents": {"surfaceId": "s1", "components": [{"id": "root", "component": "Text", "text": "a"}]}}]|

      assert decompile!(v1, Jason.decode!(json, objects: :ordered_objects)) ==
               ~s|surface("s1")\nroot = Text("a")|
    end

    test "lists of component ids are references" do
      catalog =
        ~s|{"catalogId": "urn:k", "protocolVersion": "v1.0", "components": {"Group": {"type": "object", "properties": {"component": {"const": "Group"}, "kids": {"type": "array", "items": {"$ref": "common_types.json#/$defs/ComponentId"}}}}}}|
        |> Jason.decode!(objects: :ordered_objects)
        |> Catalog.from_json!()

      {:ok, catalogs} = Catalogs.new([catalog])

      messages = [
        %{
          "version" => "v1.0",
          "createSurface" => %{
            "surfaceId" => "s1",
            "catalogId" => "urn:k",
            "components" => [
              %{"id" => "root", "component" => "Group", "kids" => ["a"]},
              %{"id" => "a", "component" => "Group"}
            ]
          }
        }
      ]

      assert decompile!(catalogs, messages) == ~s|surface("s1")\nroot = Group([a])\na = Group()|
    end
  end

  test "v0.9 messages decompile with their plain keys", %{v09: v09} do
    assert round_trip!(v09, ~s|root = TextField("N", $/n, ?required)\n$/n = ""|) =~
             ~s|root = TextField("N", $/n, ?required)|
  end

  test "variable_names/1 derives distinct names" do
    assert Decompiler.variable_names(["a-b", "a_b", "a-b-", "9x", ""]) == %{
             "a-b" => "a_b_2",
             "a_b" => "a_b",
             "a-b-" => "a_b_",
             "9x" => "_9x",
             "" => "_"
           }
  end
end

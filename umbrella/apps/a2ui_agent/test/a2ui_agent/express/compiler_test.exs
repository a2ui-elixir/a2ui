defmodule A2UIAgent.Express.CompilerTest do
  @moduledoc false
  use ExUnit.Case, async: true

  import A2UIAgent.Test.Fixtures

  alias A2UIAgent.Express.{Catalogs, Compiler}
  alias A2UICore.{Catalog, Error}

  doctest Compiler

  setup_all do
    {:ok, v1} = Catalogs.new([Catalog.Basic.catalog("v1.0")])
    {:ok, v09} = Catalogs.new([Catalog.Basic.catalog("v0.9.1")])
    %{v1: v1, v09: v09}
  end

  # A catalog read in document order, as Express needs.
  defp ordered_catalog(json),
    do: json |> Jason.decode!(objects: :ordered_objects) |> Catalog.from_json!()

  defp compile!(catalogs, source, options \\ []) do
    assert {:ok, messages} = Compiler.compile(catalogs, source, options)
    messages
  end

  defp error(catalogs, source, options \\ []) do
    assert {:error, %Error{} = error} = Compiler.compile(catalogs, source, options)
    error
  end

  defp components(catalogs, source) do
    [%{"createSurface" => %{"components" => components}}] = compile!(catalogs, source)
    Map.new(components, &{&1["id"], &1})
  end

  describe "surfaces" do
    test "a block with a root creates the default surface", %{v1: v1} do
      assert compile!(v1, ~s|root = Text("Hi")|, surface_id: "main") == [
               %{
                 "version" => "v1.0",
                 "createSurface" => %{
                   "surfaceId" => "main",
                   "catalogId" => basic_id(),
                   "components" => [%{"id" => "root", "component" => "Text", "text" => "Hi"}]
                 }
               }
             ]
    end

    test "surface lines open surfaces, with their keyword arguments", %{v1: v1} do
      source = """
      surface("a", sendDataModel=true)
      root = Text("A")
      $/n = 1
      surface("b", "#{basic_id()}", update=true)
      root = Text("B")
      surface("c", catalogId="#{basic_id()}", sendDataModel=false)
      root = Text("C")
      """

      assert [
               %{"createSurface" => a},
               %{"updateComponents" => %{"surfaceId" => "b"}},
               %{"createSurface" => c}
             ] = compile!(v1, source)

      assert a["sendDataModel"] == true and a["dataModel"] == %{"n" => 1}
      assert c["sendDataModel"] == false
    end

    test "a surface without a root updates components, and data alone updates data",
         %{v1: v1} do
      assert [
               %{"updateComponents" => %{"surfaceId" => "s", "components" => [_]}},
               %{
                 "updateDataModel" => %{"surfaceId" => "s", "path" => "/", "value" => %{"a" => 1}}
               }
             ] = compile!(v1, ~s|surface("s")\nlabel = Text("x")\n$/a = 1|)

      assert [%{"updateDataModel" => %{"path" => "/", "value" => %{"title" => "x"}}}] =
               compile!(v1, ~s|$/title = "x"|)

      assert [%{"updateDataModel" => %{"path" => "/", "value" => 1}}] = compile!(v1, "$ = 1")
    end

    test "a single assignment below the top level updates its path", %{v1: v1} do
      assert [%{"updateDataModel" => %{"path" => "/user/name", "value" => "Ada"}}] =
               compile!(v1, ~s|$/user/name = "Ada"|)

      assert [
               %{
                 "updateDataModel" => %{
                   "path" => "/",
                   "value" => %{"user" => %{"name" => "Ada"}, "a" => 1}
                 }
               }
             ] =
               compile!(v1, ~s|$/user/name = "Ada"
$/a = 1|)

      assert [%{"updateDataModel" => %{"path" => "/", "value" => %{"x" => 1, "y" => 2}}}] =
               compile!(v1, ~s|$ = {x: 1}
$/y = 2|)
    end

    test "deleteSurface takes the id positionally or by keyword", %{v1: v1} do
      assert [
               %{"deleteSurface" => %{"surfaceId" => "a"}},
               %{"deleteSurface" => %{"surfaceId" => "b"}}
             ] = compile!(v1, ~s|deleteSurface("a")\ndeleteSurface(surfaceId="b")|)

      assert error(v1, "deleteSurface()").message =~ "requires the id of the surface"
      assert error(v1, "deleteSurface(1)").category == :validation
    end

    test "before v1.0 a surface is created, then filled", %{v09: v09} do
      assert [
               %{"version" => "v0.9.1", "createSurface" => create},
               %{"updateComponents" => %{"components" => [%{"id" => "root"}]}},
               %{"updateDataModel" => %{"value" => %{"a" => true}}}
             ] = compile!(v09, ~s|root = Text($/a)\n$/a = true|)

      refute Map.has_key?(create, "components")
      assert create["catalogId"] == Catalog.Basic.catalog("v0.9.1").catalog_id
    end

    test "surface() checks its arguments", %{v1: v1} do
      for {source, message} <- [
            {"surface()", "requires at least 1 argument"},
            {~s|surface("a", "b", "c")|, "at most 2 positional arguments"},
            {"surface(1)", "must be a string literal"},
            {~s|surface("a", 2)|, "must be a catalog ID string"},
            {~s|surface("a", "x", catalogId="y")|, "Duplicate catalogId"},
            {~s|surface("a", catalogId=1)|, "catalogId argument to surface() must be a string"},
            {~s|surface("a", sendDataModel=1)|, "sendDataModel argument"},
            {~s|surface("a", update="yes")|, "update argument"},
            {~s|surface("a", theme=1)|, "Unknown keyword argument 'theme'"},
            {~s|surface("a", "nope")|, "targets unknown catalog 'nope'"}
          ] do
        assert %Error{category: :validation} = error = error(v1, source <> "\nroot = Text(\"x\")")
        assert error.message =~ message
      end
    end

    test "a block with nothing to compile has no root", %{v1: v1} do
      assert %Error{category: :parse, message: message} = error(v1, "")
      assert message =~ "Root target 'root' is not defined."
      assert message =~ "Help: Ensure root component 'root' is assigned"
      assert error(v1, ~s|surface("s")|).category == :parse
      assert error(v1, "1 + 2").category == :parse
    end

    test "lines outside the tags are dropped", %{v1: v1} do
      source = "ignored = 1\n<a2ui>root = Text(\"In\")\nb = Text(\"x\")</a2ui>\nalso = ignored"
      assert %{"root" => _, "b" => _} = components(v1, source)
      assert %{"root" => _} = components(v1, "<a2ui>\nroot = Text(\"In\")\n</a2ui>")
    end
  end

  describe "renderer function calls" do
    test "a standalone call is a callRendererFunction", %{v1: v1} do
      assert [
               %{
                 "callRendererFunction" => %{
                   "functionCallId" => "call_1",
                   "callFunction" => first
                 }
               },
               %{
                 "callRendererFunction" => %{"functionCallId" => "mine", "callFunction" => second}
               }
             ] =
               compile!(
                 v1,
                 ~s|openUrl("https://a.test")\nopenUrl(url="https://b.test", functionCallId="mine")|
               )

      assert first == %{
               "@call" => "openUrl",
               "catalogId" => basic_id(),
               "args" => %{"url" => "https://a.test"}
             }

      assert second["args"] == %{"url" => "https://b.test"}
    end

    test "it needs v1.0 and a usable id", %{v1: v1, v09: v09} do
      assert error(v09, ~s|openUrl("x")|).message =~ "not supported in A2UI v0.9"
      assert error(v1, ~s|openUrl("x", functionCallId="")|).message =~ "functionCallId"
      assert error(v1, ~s|Text("x")|).message =~ "Function 'Text' is not defined"
    end

    test "a call inside a surface sees its variables", %{v1: v1} do
      assert [_create, %{"callRendererFunction" => %{"callFunction" => call}}] =
               compile!(v1, ~s|root = Text("a")\nlink = "https://x.test"\nopenUrl(link)|)

      assert call["args"] == %{"url" => "https://x.test"}
    end
  end

  describe "component arguments" do
    test "positional, skipped and keyword arguments", %{v1: v1} do
      components =
        components(
          v1,
          ~s|root = Column([a, b], _, "center")\na = Text("A", variant="caption")\nb = Image("u", _, "cover", "icon", 1, 2)|
        )

      assert components["root"] == %{
               "id" => "root",
               "component" => "Column",
               "children" => ["a", "b"],
               "align" => "center"
             }

      assert components["a"]["variant"] == "caption"
      assert components["b"]["fit"] == "cover"
    end

    test "an argument naming no property, twice, or leaving out a required one", %{v1: v1} do
      assert %Error{category: :validation, message: message} =
               error(v1, ~s|root = Text("a", color="red")|)

      assert message =~ "Property 'color' is not a valid property of component 'Text'."
      assert message =~ "Help: Component 'Text' accepts properties: text, variant, weight."

      assert error(v1, ~s|root = Text("a", text="b")|).message =~ "provided multiple times"

      assert error(v1, "root = Button(action=Event(\"x\"))").message =~
               "missing required property 'child'"
    end

    test "enumerations and static properties", %{v1: v1} do
      assert error(v1, ~s|root = Text("a", "huge")|).message =~
               "Value 'huge' is not a valid enum choice for property 'variant' of component 'Text'. " <>
                 "Allowed values are: ['caption', 'body']"

      assert error(v1, ~s|root = Text("a", $/v)|).message =~
               "Property 'variant' of component 'Text' does not support dynamic data bindings"

      assert error(v1, ~s|root = Tabs([{title: "t", child: $/c}])|).message =~ "does not support"

      tabs = components(v1, ~s|root = Tabs([{title: $/t, child: body}])\nbody = Text("x")|)
      assert tabs["root"]["tabs"] == [%{"title" => %{"@path" => "/t"}, "child" => "body"}]
    end

    test "plain strings in an option list become options", %{v1: v1} do
      source =
        ~s|root = ChoicePicker("Pick", "mutuallyExclusive", ["a", {label: "B", value: "b"}], $/v)|

      assert components(v1, source)["root"]["options"] == [
               %{"label" => "a", "value" => "a"},
               %{"label" => "B", "value" => "b"}
             ]
    end

    test "an explicit id names the component", %{v1: v1} do
      components = components(v1, ~s|root = Card(body)\nbody = Text("x", id="content-1")|)
      assert components["root"]["child"] == "content-1"
      assert Map.has_key?(components, "content-1")

      assert error(v1, ~s|root = Text("x", id="")|).message =~ "id on component 'Text' must be"

      assert error(v1, ~s|root = Card(c)\nc = Text("x", id=1)|).message =~
               "must be a non-empty string"
    end
  end

  describe "values" do
    test "variables: components by id, other values substituted", %{v1: v1} do
      source = """
      title = "Hello"
      go = Event("go", {who: $/name})
      root = Column([label, Button(Text(title), action=go)])
      label = Text(title)
      """

      components = components(v1, source)
      assert components["root"]["children"] == ["label", "root_children_1"]

      assert components["root_children_1"]["action"] == %{
               "event" => %{"name" => "go", "context" => %{"who" => %{"@path" => "/name"}}}
             }

      assert components["root_children_1_child"]["text"] == "Hello"
      assert components["label"]["text"] == "Hello"
    end

    test "an undefined variable is its own name, and a cycle is an error", %{v1: v1} do
      assert components(v1, "root = Card(elsewhere)")["root"]["child"] == "elsewhere"
      assert error(v1, "a = b\nb = a\nroot = Text(a)").message =~ "defined in terms of itself"
    end

    test "events, actions and function calls", %{v1: v1} do
      source = """
      root = Row([plain, ctx, fn, merged])
      plain = Button(Text("a"), action=Event("p"))
      ctx = Button(Text("b"), _, Event("c", {}))
      fn = Button(Text("c"), action=openUrl("https://x.test"))
      merged = Button(Text("d"), action=Event("m", [{a: 1}, {b: 2}, 3]))
      """

      components = components(v1, source)
      assert components["plain"]["action"] == %{"event" => %{"name" => "p"}}
      assert components["ctx"]["action"] == %{"event" => %{"name" => "c", "context" => %{}}}

      assert components["fn"]["action"] == %{
               "functionCall" => %{"@call" => "openUrl", "args" => %{"url" => "https://x.test"}}
             }

      assert components["merged"]["action"]["event"]["context"] == %{"a" => 1, "b" => 2}

      assert components(v1, ~s|root = Button(Text("x"), action=Event())|)["root"]["action"] ==
               %{"event" => %{"name" => ""}}

      assert components(v1, ~s|root = Button(Text("x"), action=Event("e", "odd"))|)["root"][
               "action"
             ] ==
               %{"event" => %{"name" => "e", "context" => %{}}}
    end

    test "a call outside an action is the call itself", %{v1: v1} do
      assert components(v1, ~s|root = Text(formatString("${/a}"))|)["root"]["text"] ==
               %{"@call" => "formatString", "args" => %{"value" => "${/a}"}}
    end

    test "templates", %{v1: v1} do
      components = components(v1, "root = List(_template($/items, row))\nrow = Text($name)")
      assert components["root"]["children"] == %{"path" => "/items", "componentId" => "row"}

      inline = components(v1, ~s|root = List(_template($/items, Text($)))|)
      assert inline["root"]["children"]["componentId"] == "_inline_1"
      assert inline["_inline_1"]["text"] == %{"@path" => ""}

      assert %Error{category: :parse} = error(v1, "root = List(_template($/items))")
      assert error(v1, ~s|root = List(_template("items", row))|).message =~ "got: items"

      assert error(v1, "root = List(_template(rows, row))").message =~
               ~s|got: {"variable":"rows"}|

      assert error(v1, "root = List(_template(?required, row))").message =~ "_template"
    end

    test "maps, lists, skipped values and literals", %{v1: v1} do
      assert [%{"updateDataModel" => %{"value" => value}}] =
               compile!(v1, ~s|$/a = {x: [1, 2.5, true, null, _], "y z": $/p}|)

      assert value == %{
               "a" => %{
                 "x" => [1, 2.5, true, nil, %{"skipped" => true}],
                 "y z" => %{"@path" => "/p"}
               }
             }
    end
  end

  describe "inline components" do
    test "take ids from their parent and property, and come after it", %{v1: v1} do
      assert [%{"createSurface" => %{"components" => components}}] =
               compile!(v1, ~s|root = Card(Column([Text("a"), Card(Text("b"))]))|)

      assert Enum.map(components, & &1["id"]) == [
               "root",
               "root_child",
               "root_child_children_0",
               "root_child_children_1",
               "root_child_children_1_child"
             ]
    end

    test "an id that collides is an error", %{v1: v1} do
      assert error(v1, ~s|root = Card(Text("a"))\nroot_child = Text("b")|).message =~
               "Generated inline component ID 'root_child' collides"

      assert error(v1, ~s|root = Card(Text("a"))\nother = Text("b", id="root_child")|).message =~
               "collides"

      assert error(
               v1,
               ~s|root = Row([a, b])\na = Card(Text("x"), id="p")\nb = Card(Text("y"), id="p")|
             ).message =~
               "Generated inline component ID 'p_child' collides"
    end
  end

  describe "checks" do
    test "a check gets the component's bound value and a default message", %{v1: v1} do
      field = components(v1, ~s|root = TextField("Name", $/name, ?required)|)["root"]

      assert field["checks"] == [
               %{
                 "condition" => %{
                   "@call" => "required",
                   "args" => %{"value" => %{"@path" => "/name"}}
                 },
                 "message" => "Required check failed"
               }
             ]
    end

    test "arguments, messages and lists of checks", %{v1: v1} do
      source =
        ~s|root = TextField("N", $/n, checks=[?regex("^a", "Starts with a"), ?length(_, 2, "Too short"), ?email($/other)])|

      [regex, length, email] = components(v1, source)["root"]["checks"]

      assert regex == %{
               "condition" => %{
                 "@call" => "regex",
                 "args" => %{"value" => %{"@path" => "/n"}, "pattern" => "^a"}
               },
               "message" => "Starts with a"
             }

      assert length["condition"]["args"] == %{"value" => %{"@path" => "/n"}, "max" => 2}
      assert length["message"] == "Too short"
      assert email["condition"]["args"] == %{"value" => %{"@path" => "/other"}}
      assert email["message"] == "Email check failed"
    end

    test "a string where a number goes is the message", %{v1: v1} do
      [check] =
        components(v1, ~s|root = TextField("N", $/n, ?length("Bad length", 3))|)["root"]["checks"]

      assert check["message"] == "Bad length"
      assert check["condition"]["args"] == %{"value" => %{"@path" => "/n"}}
    end

    test "a check as a value is its condition", %{v1: v1} do
      assert components(v1, ~s|root = Text(formatString(?required("x")))|)["root"]["text"] ==
               %{
                 "@call" => "formatString",
                 "args" => %{"value" => %{"@call" => "required", "args" => %{"value" => "x"}}}
               }
    end

    test "a component without a check property takes no checks", %{v1: v1} do
      assert %Error{message: message} = error(v1, ~s|root = Text("a", ?required)|)
      assert message =~ "Component 'Text' does not accept checks."
      assert message =~ "Help: Remove the check expressions"
    end

    test "check options name a catalog", %{v1: v1} do
      [check] =
        components(v1, ~s|root = TextField("N", $/n, ?required({catalogId: "#{basic_id()}"}))|)[
          "root"
        ]["checks"]

      assert check["condition"]["catalogId"] == basic_id()

      assert error(v1, ~s|root = TextField("N", $/n, ?required({catalogId: "a", x: 1}))|).message =~
               "Unsupported key(s) in check options for '?required': x."

      assert error(
               v1,
               ~s|root = TextField("N", $/n, ?required({catalogId: "a"}, {catalogId: "b"}))|
             ).message =~
               "conflicting catalogId"

      [ignored] =
        components(v1, ~s|root = TextField("N", $/n, ?required({k: 1}))|)["root"]["checks"]

      assert ignored["condition"]["args"] == %{"value" => %{"@path" => "/n"}}
    end
  end

  describe "function arguments" do
    test "keyword arguments name parameters", %{v1: v1} do
      text =
        components(v1, ~s|root = Text(formatNumber(value=$/n, decimals=2, grouping=_))|)["root"][
          "text"
        ]

      assert text["args"] == %{"value" => %{"@path" => "/n"}, "decimals" => 2}

      text = components(v1, ~s|root = Text(formatNumber($/n, _, null))|)["root"]["text"]
      assert text["args"] == %{"value" => %{"@path" => "/n"}}

      assert %Error{message: message} = error(v1, ~s|root = Text(formatNumber($/n, places=2))|)
      assert message =~ "Argument 'places' is not a valid parameter of function 'formatNumber'."
      assert message =~ "accepts parameters: decimals, grouping, value."

      assert error(v1, ~s|root = Text(formatNumber($/n, value=1))|).message =~
               "provided multiple times"

      assert error(v1, ~s|root = Text(formatNumber($/n, x=null))|).message =~
               "not a valid parameter"

      assert error(v1, ~s|root = Text(nope(1))|).message =~
               "Function 'nope' is not defined in the catalog."
    end

    test "a function without parameters says so" do
      catalog =
        ordered_catalog(
          ~s|{"catalogId": "urn:t", "protocolVersion": "v1.0", "components": {"Text": {"type": "object", "properties": {"text": {}}}}, "functions": {"now": {"type": "object", "properties": {"@call": {"const": "now"}, "args": {"type": "object", "properties": {}}}}}}|
        )

      {:ok, catalogs} = Catalogs.new([catalog])

      assert error(catalogs, ~s|root = Text(now(x=1))|).message =~
               "Function 'now' accepts no parameters."
    end
  end

  describe "syntax errors" do
    test "a final block reports the first error with its place", %{v1: v1} do
      assert %Error{category: :parse, message: message} = error(v1, "root = Text(,)")

      assert message ==
               "Failed to parse expression: Syntax error at line 1:12: mismatched input ',' " <>
                 "expecting an expression (line 1) - Line 1, Col 12 - Help: Please correct the " <>
                 "syntax error in your Express DSL."

      assert error(v1, ~s|root = Text("a") @|).message =~
               "Syntax error at line 1:17: token recognition error at: '@' (line 1)"
    end

    test "a block that is not final compiles what comes before the error", %{v1: v1} do
      assert [%{"createSurface" => %{"components" => [%{"id" => "root"}]}}] =
               compile!(v1, ~s|root = Text("a")\nb = Text(|, final: false)
    end
  end

  describe "several catalogs" do
    setup do
      {:ok, catalogs} =
        Catalogs.new([catalog("urn:a", ["Text", "Badge"]), catalog("urn:b", ["Text", "Chip"])])

      %{multi: catalogs}
    end

    test "components carry their catalog and the surface names none", %{multi: multi} do
      source = ~s|root = Badge(text="x")\nchip = Chip()\nother = Text(catalogId="urn:b")|

      assert [%{"createSurface" => create}] = compile!(multi, source)
      refute Map.has_key?(create, "catalogId")

      assert Enum.map(create["components"], &{&1["id"], &1["catalogId"]}) ==
               [{"root", "urn:a"}, {"chip", "urn:b"}, {"other", "urn:b"}]
    end

    test "a shared name needs a catalog", %{multi: multi} do
      assert error(multi, "root = Text()").message =~
               "Component 'Text' is defined in several catalogs: 'urn:a', 'urn:b'. Name the catalog"

      assert error(multi, ~s|root = Text(catalogId="urn:x")|).message =~
               "Component 'Text' targets unknown catalog 'urn:x'. Active catalogs: 'urn:a', 'urn:b'."

      assert error(multi, ~s|root = Chip(catalogId="urn:a")|).message =~
               "Component 'Chip' is not in catalog 'urn:a'. It is defined in: 'urn:b'."

      assert error(multi, ~s|root = Badge(catalogId="")|).message =~ "must be a non-empty string"
      assert error(multi, ~s|surface("s", "urn:a")\nroot = Badge()|).message =~ "names no catalog"
    end

    test "catalogId arguments need v1.0", %{v09: v09} do
      assert error(v09, ~s|root = Text("a", catalogId="x")|).message =~
               "only supported in A2UI v1.0"
    end

    test "a name for a function in another catalog is not a component" do
      functions = %{
        "tint" => %{
          "type" => "object",
          "properties" => %{
            "args" => %{"type" => "object", "properties" => %{"v" => %{"type" => "string"}}}
          }
        }
      }

      {:ok, catalogs} =
        Catalogs.new([
          catalog("urn:a", ["Text"]),
          Catalog.from_json!(%{
            "catalogId" => "urn:f",
            "protocolVersion" => "v1.0",
            "components" => %{},
            "functions" => functions
          })
        ])

      assert [%{"createSurface" => %{"components" => [root]}}] =
               compile!(catalogs, ~s|t = tint("x", catalogId="urn:f")\nroot = Text(text=t)|)

      assert root["text"] == %{"@call" => "tint", "catalogId" => "urn:f", "args" => %{"v" => "x"}}
    end
  end

  test "statements that are neither calls nor assignments are ignored", %{v1: v1} do
    assert [%{"createSurface" => _}] = compile!(v1, ~s|"note"\n$/x\nroot = Text("a")|)
  end

  test "a variable assigned twice keeps its place and takes its last value", %{v1: v1} do
    assert [%{"createSurface" => %{"components" => components}}] =
             compile!(v1, ~s|a = Text("x")\nroot = Column([a])\na = Text("y")|)

    assert Enum.map(components, &{&1["id"], &1["text"]}) == [{"a", "y"}, {"root", nil}]
  end

  test "a component without properties says so", %{v1: v1} do
    catalog =
      ordered_catalog(
        ~s|{"catalogId": "urn:e", "protocolVersion": "v1.0", "components": {"Spacer": {"type": "object"}}}|
      )

    {:ok, catalogs} = Catalogs.new([catalog])

    assert error(catalogs, "root = Spacer(size=1)").message =~
             "Component 'Spacer' has no configurable properties."

    assert error(v1, ~s|x = openUrl("u", catalogId=1)\nroot = Text("a")|).message =~
             "catalogId on component 'openUrl' must be a non-empty string"

    assert Compiler.default_message("") == " check failed"
  end

  test "set_path/3 replaces a non-object on the way" do
    assert Compiler.set_path(%{"a" => %{"x" => 1}}, "$/a/b", 2) == %{"a" => %{"x" => 1, "b" => 2}}
    assert Compiler.set_path(%{"a" => 1}, "$/a/b", 2) == %{"a" => %{"b" => 2}}
    assert Compiler.set_path(%{}, "$", 2) == %{}
    assert Compiler.set_path(%{}, "plain", 2) == %{"plain" => 2}
    assert Compiler.set_path(%{}, "$name", 2) == %{"name" => 2}
  end
end

defmodule A2UICore.Functions.MCPTest do
  @moduledoc false
  use ExUnit.Case, async: true

  alias A2UICore.Catalog
  alias A2UICore.Catalog.MCP, as: MCPCatalog
  alias A2UICore.Resolution.DataContext
  alias A2UICore.State.DataModel

  doctest A2UICore.Catalog.MCP

  # An MCP server whose replies the test decides: `results` by tool name,
  # `resources` by URI, `tools` for `tools/list`. Calls are reported to
  # the test process.
  defmodule FakeServer do
    @moduledoc false
    @behaviour A2UICore.MCP.Client

    @impl true
    def call_tool(state, name, arguments) do
      send(state.test, {:call_tool, name, arguments})

      case Map.fetch!(state.results, name) do
        :raise -> raise ArgumentError, "server crashed"
        reply -> reply
      end
    end

    @impl true
    def read_resource(state, uri) do
      send(state.test, {:read_resource, uri})
      Map.get(state.resources, uri, {:error, "no resource #{uri}"})
    end

    @impl true
    def list_tools(state), do: Map.get(state, :tools, {:ok, []})
  end

  # A client that can only call tools.
  defmodule ToolsOnly do
    @moduledoc false
    @behaviour A2UICore.MCP.Client

    @impl true
    def call_tool(_state, _name, _arguments) do
      {:ok, %{"content" => [], "_meta" => %{"ui" => %{"resourceUri" => "ui://card"}}}}
    end
  end

  @a2ui "application/a2ui+json"
  @app "text/html;profile=mcp-app"

  defp server(results, extra \\ %{}),
    do: {FakeServer, Map.merge(%{test: self(), results: results, resources: %{}}, extra)}

  defp evaluate(version, call, options \\ [], data \\ %{}, path \\ "/") do
    catalog = MCPCatalog.catalog(version, options)

    context =
      DataContext.new(path,
        data_model: DataModel.new(data),
        catalog: catalog,
        protocol_version: version,
        surface_id: "s"
      )

    DataContext.resolve_dynamic_value(context, call)
  end

  defp v09(name, args), do: %{"call" => name, "args" => args}
  defp v10(name, args), do: %{"@call" => name, "args" => args}

  defp expression_error!({nil, effects}) do
    assert [{:error, %{code: "EXPRESSION_ERROR", message: message}} | _] = effects
    message
  end

  defp text_result(text), do: %{"content" => [%{"type" => "text", "text" => text}]}

  defp embedded(messages, uri \\ "a2ui://data") do
    %{
      "type" => "resource",
      "resource" => %{"uri" => uri, "mimeType" => @a2ui, "text" => Jason.encode!(messages)}
    }
  end

  describe "the catalog" do
    test "v0.9 declares the six functions and no components" do
      catalog = MCPCatalog.catalog("v0.9")

      assert catalog.catalog_id ==
               "https://a2ui.org/specification/v0_9/catalogs/mcp/mcp_catalog.json"

      assert Map.keys(catalog.components) == []

      assert catalog.functions |> Map.keys() |> Enum.sort() ==
               ~w(callMcpTool jmespath regexCapture regexReplace split updateDataModel)

      assert Enum.all?(catalog.functions, fn {_name, function} -> function.execute end)
      assert MCPCatalog.catalog_id("v0.9.1") == catalog.catalog_id
    end

    test "v1.0 declares callMcpTool and the McpApp component" do
      catalog = MCPCatalog.catalog("v1.0")
      assert Map.keys(catalog.components) == ["McpApp"]
      assert Catalog.get_function(catalog, "callMcpTool").execute
      assert Catalog.get_function(catalog, "@index")
      assert MCPCatalog.declared("v1.0") == MCPCatalog.declared("v1.0")
    end

    test "implement/3 attaches the functions to a catalog that copies them" do
      declared = MCPCatalog.declared("v0.9")
      refute Catalog.get_function(declared, "split").execute
      assert Catalog.get_function(MCPCatalog.implement(declared, "v0.9"), "split").execute
    end
  end

  describe "split" do
    test "splits a string, or each string of an array" do
      assert {["a", "b", ""], []} =
               evaluate("v0.9", v09("split", %{"value" => "a,b,", "separator" => ","}))

      assert {[["a", "b"], ["c"]], []} =
               evaluate("v0.9", v09("split", %{"value" => ["a b", "c"], "separator" => " "}))
    end

    test "an empty separator splits into characters" do
      assert {["h", "é"], []} =
               evaluate("v0.9", v09("split", %{"value" => "hé", "separator" => ""}))

      assert {[], []} = evaluate("v0.9", v09("split", %{"value" => "", "separator" => ""}))
    end

    test "values are read as text" do
      assert {[["1", "5"], ["true"]], []} =
               evaluate(
                 "v0.9",
                 v09("split", %{"value" => %{"path" => "/items"}, "separator" => "."}),
                 [],
                 %{"items" => [1.5, true]}
               )
    end
  end

  describe "regexCapture" do
    test "returns the groups of the first match, or nil" do
      args = %{"value" => "id-42 id-7", "pattern" => "id-(\\d+)"}
      assert {["42"], []} = evaluate("v0.9", v09("regexCapture", args))

      assert {nil, []} =
               evaluate("v0.9", v09("regexCapture", %{"value" => "x", "pattern" => "(\\d)"}))
    end

    test "unmatched optional groups are empty strings" do
      args = %{"value" => "ab", "pattern" => "(a)(x)?(b)(y)?"}
      assert {["a", "", "b", ""], []} = evaluate("v0.9", v09("regexCapture", args))
    end

    test "works element by element and follows RE2's `$` and ASCII classes" do
      args = %{"value" => ["a1", "b", "c٣"], "pattern" => "^[a-c](\\d)$"}
      assert {[["1"], nil, nil], []} = evaluate("v0.9", v09("regexCapture", args))

      assert {nil, []} =
               evaluate("v0.9", v09("regexCapture", %{"value" => "a\n", "pattern" => "a$"}))
    end

    test "a pattern that cannot be padded still captures" do
      args = %{"value" => "ab", "pattern" => "(?x)(a) # comment"}
      assert {["a"], []} = evaluate("v0.9", v09("regexCapture", args))
    end

    test "an invalid pattern is an expression error" do
      result = evaluate("v0.9", v09("regexCapture", %{"value" => "x", "pattern" => "("}))
      assert expression_error!(result) =~ "Invalid RE2 pattern '(' in regexCapture"
    end
  end

  describe "regexReplace" do
    test "replaces every match with literal text" do
      args = %{"value" => "a1b22", "pattern" => "(\\d+)", "replacement" => "<$1>"}
      assert {"a<$1>b<$1>", []} = evaluate("v0.9", v09("regexReplace", args))

      args = %{"value" => ["x-y", "z"], "pattern" => "-", "replacement" => ""}
      assert {["xy", "z"], []} = evaluate("v0.9", v09("regexReplace", args))
    end

    test "an invalid pattern is an expression error" do
      args = %{"value" => "x", "pattern" => "[", "replacement" => ""}
      assert expression_error!(evaluate("v0.9", v09("regexReplace", args))) =~ "regexReplace"
    end
  end

  describe "jmespath" do
    test "evaluates an expression against data" do
      args = %{"expression" => "items[?done].title", "data" => %{"path" => "/todo"}}
      data = %{"todo" => %{"items" => [%{"title" => "a", "done" => true}, %{"title" => "b"}]}}
      assert {["a"], []} = evaluate("v0.9", v09("jmespath", args), [], data)
    end

    test "a bad expression is an expression error naming it" do
      result = evaluate("v0.9", v09("jmespath", %{"expression" => "a[", "data" => [1]}))
      assert expression_error!(result) =~ "in JMESPath expression: a["
    end

    test "the expression must be a string" do
      for {value, kind} <- [{nil, "null"}, {%{"a" => 1}, "an object"}] do
        args = %{"expression" => %{"path" => "/e"}, "data" => [1]}
        result = evaluate("v0.9", v09("jmespath", args), [], %{"e" => value})
        assert expression_error!(result) == "jmespath expects a string expression, got #{kind}."
      end

      args = %{"expression" => %{"path" => "/n"}, "data" => [1]}
      result = evaluate("v0.9", v09("jmespath", args), [], %{"n" => 5})
      assert expression_error!(result) == "jmespath expects a string expression, got a number."
    end
  end

  describe "updateDataModel" do
    test "asks for one write per entry, relative paths in the calling scope" do
      args = %{"updates" => %{"path" => "/pending"}}
      data = %{"pending" => %{"/title" => "Home", "name" => "Ada"}}

      assert {nil, writes} = evaluate("v0.9", v09("updateDataModel", args), [], data, "/rows/2")

      assert Enum.sort(writes) == [
               {:write, %{path: "/rows/2/name", value: "Ada"}},
               {:write, %{path: "/title", value: "Home"}}
             ]
    end

    test "updates usually come from a call shaping data (v0.9 has no object literals)" do
      shape = v09("jmespath", %{"expression" => ~S|{"/count": length(@)}|, "data" => [1, 2, 3]})

      assert {nil, [{:write, %{path: "/count", value: 3}}]} =
               evaluate("v0.9", v09("updateDataModel", %{"updates" => shape}))

      literal = v09("updateDataModel", %{"updates" => %{"/a" => 1}})
      assert {nil, [{:error, %{code: "EXPRESSION_ERROR"}}]} = evaluate("v0.9", literal)
    end

    test "called directly without updates, it writes nothing" do
      execute = A2UICore.Functions.MCP.implementations("v0.9")["updateDataModel"]
      assert execute.(%{}, DataContext.new()) == {:ok, nil}
    end

    test "null updates write nothing; other values are errors" do
      args = %{"updates" => %{"path" => "/missing"}}

      assert {nil, [{:warning, %{code: "MISSING_DATA_BINDING"}}]} =
               evaluate("v0.9", v09("updateDataModel", args))

      for {value, kind} <- [{[1], "an array"}, {"x", "a string"}, {true, "a boolean"}] do
        result =
          evaluate("v0.9", v09("updateDataModel", %{"updates" => %{"path" => "/v"}}), [], %{
            "v" => value
          })

        assert expression_error!(result) ==
                 "updateDataModel expects an object of data model paths, got #{kind}."
      end
    end
  end

  describe "callMcpTool" do
    test "calls the tool with its resolved arguments and returns the result" do
      result = text_result("done")
      client = server(%{"save" => {:ok, result}})
      args = %{"name" => "save", "arguments" => %{"title" => %{"path" => "/title"}}}

      assert {^result, []} =
               evaluate("v0.9", v09("callMcpTool", args), [client: client], %{"title" => "Hi"})

      assert_received {:call_tool, "save", %{"title" => "Hi"}}
    end

    test "embedded A2UI messages come back as effects, with the catalog's version" do
      update = %{"updateDataModel" => %{"surfaceId" => "s", "path" => "/x", "value" => 1}}
      versioned = Map.put(update, "version", "v1.0")

      result = %{
        "content" => [text_result("x")["content"] |> hd(), embedded([update, versioned])]
      }

      client = server(%{"get" => {:ok, result}})

      assert {^result, [{:messages, %{messages: messages, source: :inline}}]} =
               evaluate("v0.9", v09("callMcpTool", %{"name" => "get"}), client: client)

      assert messages == [Map.put(update, "version", "v0.9"), versioned]

      odd = %{"content" => [embedded([1])]}
      odd_client = server(%{"odd" => {:ok, odd}})

      assert {_odd, [{:messages, %{messages: [1]}}]} =
               evaluate("v0.9", v09("callMcpTool", %{"name" => "odd"}), client: odd_client)

      assert {_result, [{:messages, %{messages: [%{"version" => "v1.0"} | _]}}]} =
               evaluate("v1.0", v10("callMcpTool", %{"name" => "get"}), client: client)
    end

    test "the UI resources the result names are read, before inline messages" do
      layout = %{"createSurface" => %{"surfaceId" => "card", "catalogId" => "c"}}
      data = %{"updateDataModel" => %{"surfaceId" => "card", "value" => %{}}}

      result =
        Map.merge(%{"content" => [embedded(data)]}, %{
          "_meta" => %{"ui" => %{"resourceUri" => ["ui://card", "ui://card"]}}
        })

      client =
        server(%{"show" => {:ok, result}}, %{
          resources: %{
            "ui://card" =>
              {:ok,
               %{
                 "contents" => [
                   %{"uri" => "ui://card", "mimeType" => @a2ui, "text" => Jason.encode!(layout)}
                 ]
               }}
          }
        })

      assert {^result, [{:messages, resource}, {:messages, inline}]} =
               evaluate("v0.9", v09("callMcpTool", %{"name" => "show"}), client: client)

      assert resource == %{messages: [Map.put(layout, "version", "v0.9")], source: :resource}
      assert inline.source == :inline
      assert_received {:read_resource, "ui://card"}
      refute_received {:read_resource, _uri}
    end

    test "without named resources, the tool's declared ones are read" do
      tools =
        {:ok,
         [
           %{"name" => "other"},
           %{"name" => "show", "_meta" => %{"ui" => %{"resourceUri" => "ui://x"}}}
         ]}

      contents = %{
        "contents" => [%{"uri" => "ui://x", "mimeType" => @a2ui, "text" => "{\"a\": 1}"}]
      }

      client =
        server(%{"show" => {:ok, text_result("x")}}, %{
          tools: tools,
          resources: %{"ui://x" => {:ok, contents}}
        })

      assert {_result, [{:messages, %{messages: [%{"a" => 1, "version" => "v0.9"}]}}]} =
               evaluate("v0.9", v09("callMcpTool", %{"name" => "show"}), client: client)
    end

    test "a failed tools/list only means no declared resources" do
      client = server(%{"show" => {:ok, text_result("x")}}, %{tools: {:error, "no list"}})

      assert {%{"content" => _}, []} =
               evaluate("v0.9", v09("callMcpTool", %{"name" => "show"}), client: client)
    end

    test "a client without read_resource skips the resources" do
      assert {%{"content" => []}, []} =
               evaluate("v0.9", v09("callMcpTool", %{"name" => "x"}), client: {ToolsOnly, nil})

      assert {%{"content" => []}, []} =
               evaluate("v0.9", v09("callMcpTool", %{"name" => "x"}), client: ToolsOnly)
    end

    test "with targetDataPath, the MCP App a resource holds is written there" do
      html = "<p>Pong</p>"
      ui = %{"csp" => %{"connectDomains" => []}, "permissions" => %{"camera" => true}}

      app = %{
        "uri" => "ui://pong",
        "mimeType" => @app,
        "blob" => Base.encode64(html),
        "_meta" => %{"ui" => ui}
      }

      result = %{"content" => [], "_meta" => %{"ui" => %{"resourceUri" => "ui://pong"}}}

      client =
        server(%{"play" => {:ok, result}}, %{
          resources: %{"ui://pong" => {:ok, %{"contents" => [app]}}}
        })

      call =
        v10("callMcpTool", %{
          "name" => "play",
          "arguments" => %{"level" => 2},
          "targetDataPath" => "app"
        })

      assert {^result, [{:write, %{path: "/games/1/app", value: payload}}]} =
               evaluate("v1.0", call, [client: client], %{}, "/games/1")

      assert payload == %{
               "uri" => "ui://pong",
               "htmlContent" => html,
               "csp" => ui["csp"],
               "permissions" => ui["permissions"],
               "toolInput" => %{"level" => 2},
               "toolResult" => result
             }

      assert {^result, []} =
               evaluate("v1.0", v10("callMcpTool", %{"name" => "play"}), client: client)
    end

    test "a client resolver picks the client per tool" do
      resolver = fn
        "known" -> server(%{"known" => {:ok, text_result("x")}})
        "module" -> ToolsOnly
        _unknown -> nil
      end

      assert {%{"content" => _}, []} =
               evaluate("v0.9", v09("callMcpTool", %{"name" => "known"}), client: resolver)

      assert {%{"content" => []}, []} =
               evaluate("v0.9", v09("callMcpTool", %{"name" => "module"}), client: resolver)

      result = evaluate("v0.9", v09("callMcpTool", %{"name" => "gone"}), client: resolver)

      assert expression_error!(result) ==
               "Failed to execute MCP tool 'gone': MCP client for tool 'gone' could not be resolved."
    end

    test "failures are expression errors naming the tool" do
      cases = [
        {nil, "MCP client for tool 't' could not be resolved."},
        {server(%{"t" => {:ok, nil}}), "MCP tool 't' did not return a result."},
        {server(%{"t" => {:ok, %{"isError" => true, "content" => []}}}),
         ~S(MCP tool 't' execution failed: {"content":[],"isError":true})},
        {server(%{"t" => {:error, "connection refused"}}), "connection refused"},
        {server(%{"t" => {:error, :timeout}}), ":timeout"},
        {server(%{"t" => :raise}), "server crashed"},
        {server(%{"t" => :unexpected}), "MCP tool 't' returned :unexpected"}
      ]

      for {client, reason} <- cases do
        result = evaluate("v0.9", v09("callMcpTool", %{"name" => "t"}), client: client)
        assert expression_error!(result) == "Failed to execute MCP tool 't': #{reason}"
      end
    end

    test "a resource that cannot be read, or holds broken A2UI, fails the call" do
      named = %{"content" => [], "_meta" => %{"ui" => %{"resourceUri" => "ui://r"}}}
      missing = server(%{"t" => {:ok, named}})
      result = evaluate("v0.9", v09("callMcpTool", %{"name" => "t"}), client: missing)
      assert expression_error!(result) =~ "no resource ui://r"

      broken = %{"contents" => [%{"mimeType" => @a2ui, "text" => "{"}]}
      client = server(%{"t" => {:ok, named}}, %{resources: %{"ui://r" => {:ok, broken}}})
      result = evaluate("v0.9", v09("callMcpTool", %{"name" => "t"}), client: client)
      assert expression_error!(result) =~ "Resource ui://r declares application/a2ui+json"

      odd = server(%{"t" => {:ok, named}}, %{resources: %{"ui://r" => :odd}})
      result = evaluate("v0.9", v09("callMcpTool", %{"name" => "t"}), client: odd)
      assert expression_error!(result) =~ "reading ui://r returned :odd"

      inline = %{
        "content" => [
          %{"type" => "resource", "resource" => %{"mimeType" => @a2ui, "text" => "["}}
        ]
      }

      client = server(%{"t" => {:ok, inline}})
      result = evaluate("v0.9", v09("callMcpTool", %{"name" => "t"}), client: client)
      assert expression_error!(result) =~ "does not hold valid JSON"
    end
  end
end

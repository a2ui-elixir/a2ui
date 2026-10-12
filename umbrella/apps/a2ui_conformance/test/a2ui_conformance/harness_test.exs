defmodule A2UIConformance.HarnessTest do
  @moduledoc false
  # Unit tests for the harness plumbing (YAML decoding, case metadata,
  # dispatch, matchers), independent of the upstream checkout.

  use ExUnit.Case, async: true

  alias A2UIConformance.{Case, Dispatcher, Matchers, SkipPolicy, Yaml}
  alias A2UICore.Error

  describe "Yaml" do
    test "an empty mapping decodes to %{} and an empty sequence to []" do
      assert {:ok, [doc]} = Yaml.decode_string("a: {}\nb: []\nc: null\nd: {x: [1, {}]}\n")
      assert doc == %{"a" => %{}, "b" => [], "c" => nil, "d" => %{"x" => [1, %{}]}}
    end

    test "a top-level list of cases keeps its order" do
      assert {:ok, [[%{"name" => "a"}, %{"name" => "b"}]]} =
               Yaml.decode_string("- name: a\n- name: b\n")
    end
  end

  describe "Case.resolve_protocol_version (reference L132-159)" do
    test "precedence: case, catalog, catalogSchema, first catalogs entry with a version" do
      assert Case.resolve_protocol_version(%{
               "protocolVersion" => "v1.0",
               "catalog" => %{"protocolVersion" => "v0.8"}
             }) ==
               "v1.0"

      assert Case.resolve_protocol_version(%{"catalog" => %{"protocolVersion" => "v0.9.1"}}) ==
               "v0.9.1"

      assert Case.resolve_protocol_version(%{"catalogSchema" => %{"protocolVersion" => "v1.0"}}) ==
               "v1.0"

      assert Case.resolve_protocol_version(%{
               "catalogs" => ["basic", %{"x" => 1}, %{"protocolVersion" => "v1.0"}]
             }) ==
               "v1.0"
    end

    test "catalog id heuristic and default" do
      assert Case.resolve_protocol_version(%{
               "catalogId" => "https://a2ui.org/specification/v0_8/x"
             }) == "v0.8"

      assert Case.resolve_protocol_version(%{"catalog" => %{"catalogId" => "urn:v1_0:basic"}}) ==
               "v1.0"

      assert Case.resolve_protocol_version(%{"catalogSchema" => %{"catalogId" => "v09-catalog"}}) ==
               "v0.9"

      assert Case.resolve_protocol_version(%{}) == "v0.9"
    end

    test "bare versions normalize to the v-prefixed form" do
      assert %Case{protocol_version: "v1.0"} =
               Case.new("core/x.yaml", "n", %{"protocolVersion" => "1.0"})

      assert %Case{protocol_version: "v0.9.1"} =
               Case.new("core/x.yaml", "n", %{"protocolVersion" => "0.9.1"})
    end
  end

  describe "Dispatcher" do
    defp case_for(suite, action), do: Case.new(suite, "n", %{"action" => action})

    test "keys on scope: the same action is pending in different phases per family" do
      assert {:pending, 3} =
               Dispatcher.resolve(case_for("core/data_context.yaml", "resolve_path"))

      assert {:pending, 10} =
               Dispatcher.resolve(case_for("extensions/adk/tools.yaml", "resolve_path"))

      assert {:pending, 9} = Dispatcher.resolve(case_for("extensions/a2a/rpc.yaml", "handle_rpc"))
      assert {:pending, 7} = Dispatcher.resolve(case_for("core/rpc.yaml", "handle_rpc"))

      assert {:pending, 5} =
               Dispatcher.resolve(case_for("core/catalog_selection.yaml", "select_catalog"))
    end

    test "agent families: blueprint suites are phase 10, express and legacy are optional" do
      assert {:pending, 10} =
               Dispatcher.resolve(case_for("agent/resolve_catalogs.yaml", "resolve_catalogs"))

      assert {:pending, 10} =
               Dispatcher.resolve(case_for("agent/direct_json/parser.yaml", "parse_chunk"))

      assert {:optional, 10, _} =
               Dispatcher.resolve(case_for("agent/express/compiler.yaml", "compile"))

      assert {:optional, 10, _} =
               Dispatcher.resolve(case_for("agent/legacy/parser.yaml", "select_catalog"))
    end

    test "resolve_nodes is only known in its own suite; unknown actions are unknown" do
      assert {:pending, 6} =
               Dispatcher.resolve(case_for("core/node_resolution.yaml", "resolve_nodes"))

      assert :unknown = Dispatcher.resolve(case_for("core/data_model.yaml", "resolve_nodes"))
      assert :unknown = Dispatcher.resolve(case_for("core/data_model.yaml", "compile"))
      assert :unknown = Dispatcher.resolve(case_for("agent/x.yaml", "data_model"))
      assert :unknown = Dispatcher.resolve(Case.new("core/x.yaml", "n", %{}))
    end

    test "the skip policy reports versions, phases and optional families" do
      assert {:skip, "unsupported protocol version \"v0.8\""} =
               SkipPolicy.skip_for(
                 Case.new("core/x.yaml", "n", %{
                   "action" => "validate",
                   "protocolVersion" => "v0.8"
                 })
               )

      assert {:skip, "action 'validate' lands in phase 5"} =
               SkipPolicy.skip_for(case_for("core/x.yaml", "validate"))

      assert {:skip, "optional: " <> _} =
               SkipPolicy.skip_for(case_for("agent/express/x.yaml", "wrap"))
    end
  end

  describe "Matchers.assert_error categories" do
    defp error(category), do: Error.new(category, "CODE", "boom")

    test "ValidationError accepts integrity and recursion errors (Python subclasses)" do
      for category <- [:validation, :integrity, :recursion] do
        assert Matchers.assert_error(%{"category" => "ValidationError"}, error(category))
      end

      assert_raise ExUnit.AssertionError, fn ->
        Matchers.assert_error(%{"category" => "ValidationError"}, error(:data))
      end
    end

    test "IntegrityError does not accept a plain validation error" do
      assert_raise ExUnit.AssertionError, fn ->
        Matchers.assert_error(%{"category" => "IntegrityError"}, error(:validation))
      end
    end

    test "an unknown category accepts any library error" do
      assert Matchers.assert_error(%{"category" => "SomethingNew"}, error(:state))
    end
  end

  describe "Matchers equality" do
    test "assert_json_equal compares numbers by value and maps exactly" do
      assert Matchers.assert_json_equal(%{"a" => [1, 2.0]}, %{"a" => [1.0, 2]}, "x")

      assert_raise ExUnit.AssertionError, fn ->
        Matchers.assert_json_equal(%{"a" => 1}, %{"a" => 1, "b" => 2}, "x")
      end
    end

    test "assert_strict_equal distinguishes 1 from 1.0 and names the differing path" do
      assert Matchers.assert_strict_equal(%{"a" => [1]}, %{"a" => [1]}, "doc")

      error =
        assert_raise ExUnit.AssertionError, fn ->
          Matchers.assert_strict_equal(%{"a" => [1]}, %{"a" => [1.0]}, "doc")
        end

      assert error.message =~ "/a/0"
    end
  end
end

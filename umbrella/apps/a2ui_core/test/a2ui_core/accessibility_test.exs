defmodule A2UICore.AccessibilityTest do
  @moduledoc false
  use ExUnit.Case, async: true

  doctest A2UICore.Accessibility

  alias A2UICore.Accessibility
  alias A2UICore.Catalog
  alias A2UICore.Catalog.Basic
  alias A2UICore.Resolution.DataContext
  alias A2UICore.State.{Component, DataModel}

  defp attributes(type, props, data \\ %{}) do
    context =
      DataContext.new("/", data_model: DataModel.new(data), catalog: Basic.catalog("v1.0"))

    Accessibility.attributes(Component.new("c", type, props), context)
  end

  describe "attributes/2" do
    test "explicit attributes are plumbed through" do
      props = %{
        "accessibility" => %{
          "label" => "Mute Notifications",
          "description" => "Silences notifications",
          "live" => "assertive",
          "hidden" => true
        }
      }

      assert {%{
                label: "Mute Notifications",
                description: "Silences notifications",
                live: "assertive",
                hidden: true
              }, []} = attributes("Text", props)
    end

    test "nothing declared means no label, no description, not live, not hidden" do
      assert {%{label: nil, description: nil, live: "off", hidden: false, role: nil}, []} =
               attributes("Divider", %{})
    end

    test "the label is inferred from visible text, title first" do
      assert {%{label: "Submit Form"}, []} = attributes("Button", %{"title" => "Submit Form"})
      assert {%{label: "Hi"}, []} = attributes("Text", %{"text" => "Hi"})
      assert {%{label: "Email"}, []} = attributes("TextField", %{"label" => "Email"})

      assert {%{label: "Title"}, []} =
               attributes("Card", %{"text" => "Text", "title" => "Title"})

      assert {%{label: "Text"}, []} = attributes("Card", %{"title" => "", "text" => "Text"})
    end

    test "an explicit label overrides the inferred one" do
      props = %{"title" => "Submit", "accessibility" => %{"label" => "Send Form"}}

      assert {%{label: "Send Form"}, []} = attributes("Button", props)
    end

    test "bound attributes resolve against the data model" do
      props = %{
        "title" => "Fallback",
        "text" => %{"@path" => "/text"},
        "accessibility" => %{
          "label" => %{"@path" => "/label"},
          "hidden" => %{"@path" => "/hidden"}
        }
      }

      data = %{"label" => "From data", "hidden" => true, "text" => "Shown"}

      assert {%{label: "From data", hidden: true}, []} = attributes("Button", props, data)

      assert {%{label: "Shown", hidden: false}, []} =
               attributes("Text", Map.drop(props, ["accessibility", "title"]), data)
    end

    test "an unresolved binding falls back to the inferred label and warns" do
      props = %{"title" => "Go", "accessibility" => %{"label" => %{"@path" => "/missing"}}}

      assert {%{label: "Go"}, [{:warning, %{code: "MISSING_DATA_BINDING"}}]} =
               attributes("Button", props)
    end

    test "only the three live values are honoured" do
      for value <- ~w(off polite assertive) do
        assert {%{live: ^value}, []} =
                 attributes("Text", %{"accessibility" => %{"live" => value}})
      end

      assert {%{live: "off"}, []} = attributes("Text", %{"accessibility" => %{"live" => "loud"}})
    end

    test "hidden is true only for true" do
      assert {%{hidden: false}, []} =
               attributes("Text", %{"accessibility" => %{"hidden" => "yes"}})

      assert {%{hidden: true}, []} = attributes("Text", %{"accessibility" => %{"hidden" => true}})
    end

    test "an accessibility value that is not an object is ignored" do
      assert {%{label: "Hi"}, []} =
               attributes("Text", %{"text" => "Hi", "accessibility" => "oops"})
    end

    test "interactive basic components carry their role" do
      assert {%{role: "button"}, []} = attributes("Button", %{})
      assert {%{role: "textbox"}, []} = attributes("TextField", %{})
      assert {%{role: "checkbox"}, []} = attributes("CheckBox", %{})
      assert {%{role: "radiogroup"}, []} = attributes("ChoicePicker", %{})
      assert {%{role: nil}, []} = attributes("Text", %{})
    end

    test "a checkbox reports its state from its value or checked property" do
      assert {%{checked: true}, []} = attributes("CheckBox", %{"value" => true})

      assert {%{checked: false}, []} =
               attributes("CheckBox", %{"value" => %{"@path" => "/on"}}, %{"on" => false})

      assert {%{checked: true}, []} = attributes("CheckBox", %{"checked" => true})
      assert {%{checked: nil}, []} = attributes("CheckBox", %{"value" => "maybe"})
      assert {%{checked: nil}, []} = attributes("Text", %{"value" => true})
    end
  end

  describe "lint/1" do
    defp catalog(components) do
      document = %{
        "catalogId" => "test-catalog",
        "components" => components,
        "$defs" => %{}
      }

      Catalog.from_json!(document, protocol_version: "v1.0")
    end

    defp component(properties, extra \\ %{}) do
      Map.merge(
        %{
          "type" => "object",
          "properties" => Map.put(properties, "component", %{"const" => "X"}),
          "required" => ["component"]
        },
        extra
      )
    end

    test "the basic catalogs conform" do
      for version <- ["v0.9.1", "v1.0"] do
        assert Accessibility.lint(Basic.catalog(version)) == []
      end
    end

    test "an action component with nothing to label it is reported" do
      catalog =
        catalog(%{
          "IconButton" =>
            component(%{"action" => %{"$ref" => "common_types.json#/$defs/Action"}}),
          "Banner" => component(%{"text" => %{"type" => "string"}})
        })

      assert [%{component: "IconButton", reason: reason}] = Accessibility.lint(catalog)
      assert reason =~ "label"
    end

    test "an input binding with nothing to label it is reported" do
      catalog =
        catalog(%{
          "Dial" => component(%{"value" => %{"$ref" => "common_types.json#/$defs/DynamicNumber"}})
        })

      assert [%{component: "Dial"}] = Accessibility.lint(catalog)
    end

    test "a label, title, text or child property is enough, even when optional" do
      for property <- ~w(label title text child) do
        catalog =
          catalog(%{
            "Control" =>
              component(%{
                "action" => %{"$ref" => "common_types.json#/$defs/Action"},
                property => %{"type" => "string"}
              })
          })

        assert Accessibility.lint(catalog) == []
      end
    end

    test "properties declared in an allOf member count" do
      envelope = %{
        "allOf" => [
          %{"$ref" => "common_types.json#/$defs/Checkable"},
          %{
            "properties" => %{
              "component" => %{"const" => "X"},
              "action" => %{"$ref" => "common_types.json#/$defs/Action"}
            }
          }
        ]
      }

      assert [%{component: "Wrapped"}] = Accessibility.lint(catalog(%{"Wrapped" => envelope}))
    end

    test "findings come back in component order" do
      action = %{"action" => %{"$ref" => "common_types.json#/$defs/Action"}}
      catalog = catalog(%{"Zed" => component(action), "Alpha" => component(action)})

      assert Enum.map(Accessibility.lint(catalog), & &1.component) == ["Alpha", "Zed"]
    end
  end
end

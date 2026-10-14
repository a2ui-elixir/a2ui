defmodule A2UIPhoenix.SurfaceTest do
  @moduledoc false
  use ExUnit.Case, async: true

  import Phoenix.ConnTest, only: [build_conn: 0]
  import Phoenix.LiveViewTest

  alias A2UIPhoenix.Test.{HostLive, Reference}

  @endpoint A2UIPhoenix.Test.Endpoint

  @v1 "https://a2ui.org/specification/v1_0/catalogs/basic/catalog.json"

  defp start(messages, extra \\ %{}) do
    session = Map.merge(%{"test" => self(), "messages" => messages}, extra)
    {:ok, view, html} = live_isolated(build_conn(), HostLive, session: session)
    {view, html}
  end

  defp create(surface_id, extra \\ %{}) do
    %{
      "version" => "v1.0",
      "createSurface" => Map.merge(%{"surfaceId" => surface_id, "catalogId" => @v1}, extra)
    }
  end

  defp components(surface_id, components) do
    %{
      "version" => "v1.0",
      "updateComponents" => %{"surfaceId" => surface_id, "components" => components}
    }
  end

  defp data(surface_id, path, value) do
    %{
      "version" => "v1.0",
      "updateDataModel" => %{"surfaceId" => surface_id, "path" => path, "value" => value}
    }
  end

  defp surface(id, components, data \\ %{}),
    do: [create(id), data(id, "/", data), components(id, components)]

  defp by_id(view, component_id), do: element(view, "[data-a2ui-id='#{component_id}']")

  defp input(view, component_id, field \\ "value") do
    html = view |> by_id(component_id) |> render()
    [_, ref] = Regex.run(~r/name="a2ui\[(\d+)\]\[#{field}\]/, html)
    ref
  end

  defp change(view, surface_id, ref, field, value) do
    view
    |> element("#surface-#{surface_id}-form")
    |> render_change(%{"_target" => ["a2ui", ref, field], "a2ui" => %{ref => %{field => value}}})
  end

  # A socket A2UIPhoenix.Live.init/3 never saw; built at runtime so the
  # type checker does not reject the call the test makes on purpose.
  defp bare_socket, do: struct(Phoenix.LiveView.Socket, Map.new([]))

  defp sent do
    assert_receive {:sent, message}
    message
  end

  describe "rendering" do
    test "a surface renders its tree once the root arrives" do
      {view, html} = start([create("main")])

      refute html =~ "a2ui-surface-main-form"

      send(
        view.pid,
        {:agent, components("main", [%{"id" => "root", "component" => "Text", "text" => "Hi"}])}
      )

      assert view |> by_id("root") |> render() =~ "Hi"
      assert_receive {:handled, :ok}
    end

    test "pending children are placeholders until they arrive" do
      {view, _html} =
        start(
          surface("main", [%{"id" => "root", "component" => "Column", "children" => ["late"]}])
        )

      assert render(view) =~ ~s(class="a2ui-placeholder a2ui-pending")

      send(
        view.pid,
        {:agent, components("main", [%{"id" => "late", "component" => "Text", "text" => "Now"}])}
      )

      html = render(view)
      assert html =~ "Now"
      refute html =~ "a2ui-pending"
    end

    test "a deleted surface is no longer rendered" do
      {view, _html} =
        start(surface("main", [%{"id" => "root", "component" => "Text", "text" => "Bye"}]))

      send(
        view.pid,
        {:agent, %{"version" => "v1.0", "deleteSurface" => %{"surfaceId" => "main"}}}
      )

      refute render(view) =~ "Bye"
    end

    test "bindings show the data model, and follow it" do
      {view, _html} =
        start(
          surface(
            "main",
            [%{"id" => "root", "component" => "Text", "text" => %{"@path" => "/name"}}],
            %{
              "name" => "Ada"
            }
          )
        )

      assert view |> by_id("root") |> render() =~ "Ada"
      send(view.pid, {:agent, data("main", "/name", "Grace")})
      assert view |> by_id("root") |> render() =~ "Grace"
    end

    test "templates render one child per item" do
      {view, _html} =
        start(
          surface(
            "main",
            [
              %{
                "id" => "root",
                "component" => "List",
                "children" => %{"componentId" => "item", "path" => "/items"}
              },
              %{"id" => "item", "component" => "Text", "text" => %{"@path" => "name"}}
            ],
            %{"items" => [%{"name" => "one"}, %{"name" => "two"}]}
          )
        )

      html = render(view)
      assert html =~ "one"
      assert html =~ "two"
      assert length(Regex.scan(~r/class="a2ui-list-item"/, html)) == 2
    end

    test "a host can replace a component and render markdown" do
      {view, _html} =
        start(
          surface("main", [
            %{"id" => "root", "component" => "Column", "children" => ["a"]},
            %{"id" => "a", "component" => "Text", "text" => "custom"}
          ]),
          %{"components" => ["Text"]}
        )

      assert view |> element("p.custom-text") |> render() =~ "custom"

      {view, _html} =
        start(surface("main", [%{"id" => "root", "component" => "Text", "text" => "**md**"}]), %{
          "markdown" => true
        })

      assert view |> element("p.md") |> render() =~ "**md**"
    end
  end

  describe "the contact form sample" do
    setup do
      messages = Reference.jsonl("specification/v1_0/test/cases/contact_form_example.jsonl")
      {view, _html} = start(Enum.take(messages, 3))
      %{view: view, messages: messages}
    end

    test "renders every field with its data", %{view: view} do
      assert view |> element("input[value='John']") |> has_element?()
      assert view |> element("input[value='john.doe@example.com']") |> has_element?()
      assert view |> element("input[type=radio][value=email][checked]") |> has_element?()
      assert view |> element("input[type=checkbox][checked]") |> has_element?()
      assert view |> element("button.a2ui-button.primary", "Send Message") |> has_element?()
    end

    test "typing writes the data model and re-runs the checks", %{view: view} do
      ref = input(view, "email_field")
      change(view, "contact_form_1", ref, "value", "not-an-email")

      # The write reaches the session through the LiveView process. The
      # v1.0 `email` check reports its own message.
      assert render(view) =~ "Please enter a valid email address (e.g. user@example.com)."
      assert view |> element("input[aria-invalid=true][value='not-an-email']") |> has_element?()
    end

    test "the button sends the action with its context resolved", %{view: view} do
      ref = input(view, "newsletter_checkbox")
      change(view, "contact_form_1", ref, "value", "false")
      assert_receive {:effect, {:data_model_updated, "contact_form_1", "/contact/subscribe"}}

      view |> element("button", "Send Message") |> render_click()

      assert %{"version" => "v1.0", "action" => action} = sent()
      assert action["name"] == "submitContactForm"
      assert action["surfaceId"] == "contact_form_1"
      assert action["sourceComponentId"] == "submit_button"
      assert action["timestamp"] == "2026-10-14T09:30:00Z"
      assert action["context"]["formId"] == "contact_form_1"
      assert action["context"]["isNewsletterSubscribed"] == false
      assert is_binary(action["context"]["clientTime"])
    end

    test "the surface goes away with deleteSurface", %{view: view, messages: messages} do
      send(view.pid, {:agent, List.last(messages)})
      refute render(view) =~ "Send Message"
    end
  end

  describe "inputs" do
    test "a choice picker writes a one-item list, or the checked items" do
      options = [%{"label" => "A", "value" => "a"}, %{"label" => "B", "value" => "b"}]

      {view, _html} =
        start(
          surface(
            "main",
            [
              %{"id" => "root", "component" => "Column", "children" => ["one", "many"]},
              %{
                "id" => "one",
                "component" => "ChoicePicker",
                "options" => options,
                "value" => %{"@path" => "/one"}
              },
              %{
                "id" => "many",
                "component" => "ChoicePicker",
                "variant" => "multipleSelection",
                "options" => options,
                "value" => %{"@path" => "/many"}
              }
            ],
            %{"one" => [], "many" => []}
          )
        )

      assert view |> element("[data-a2ui-id=one] [role=radiogroup]") |> has_element?()
      assert view |> element("[data-a2ui-id=many] [role=group]") |> has_element?()

      change(view, "main", input(view, "one"), "value", "b")
      assert view |> element("[data-a2ui-id=one] input[value=b][checked]") |> has_element?()

      change(view, "main", input(view, "many"), "value", ["", "a", "b"])
      assert view |> element("[data-a2ui-id=many] input[value=a][checked]") |> has_element?()
      assert view |> element("[data-a2ui-id=many] input[value=b][checked]") |> has_element?()
    end

    test "chips toggle, and a filter narrows the options locally" do
      options = for value <- ~w(apple banana cherry), do: %{"label" => value, "value" => value}

      {view, _html} =
        start(
          surface(
            "main",
            [
              %{
                "id" => "root",
                "component" => "ChoicePicker",
                "variant" => "multipleSelection",
                "displayStyle" => "chips",
                "filterable" => true,
                "options" => options,
                "value" => %{"@path" => "/picked"}
              }
            ],
            %{"picked" => ["apple"]}
          )
        )

      assert view |> element("button[aria-pressed=true]", "apple") |> has_element?()

      view |> element("button", "banana") |> render_click()
      assert view |> element("button[aria-pressed=true]", "banana") |> has_element?()

      view |> element("button", "apple") |> render_click()
      assert view |> element("button[aria-pressed=false]", "apple") |> has_element?()

      html = change(view, "main", input(view, "root", "filter"), "filter", "CHER")
      assert html =~ "cherry"
      refute html =~ "banana"
      refute_receive {:sent, _}
    end

    test "a slider writes numbers and a date-time input combines its parts" do
      {view, _html} =
        start(
          surface(
            "main",
            [
              %{"id" => "root", "component" => "Column", "children" => ["volume", "when"]},
              %{
                "id" => "volume",
                "component" => "Slider",
                "max" => 10,
                "steps" => 5,
                "value" => %{"@path" => "/volume"}
              },
              %{
                "id" => "when",
                "component" => "DateTimeInput",
                "enableTime" => true,
                "value" => %{"@path" => "/when"}
              }
            ],
            %{"volume" => 2, "when" => ""}
          )
        )

      assert view |> element("input[type=range][step='2.0']") |> has_element?()

      change(view, "main", input(view, "volume"), "value", "6")
      assert view |> element(".a2ui-slider-value", "6") |> has_element?()

      change(view, "main", input(view, "when", "time"), "time", "08:15")
      assert view |> element("input[type=date][value='2026-10-14']") |> has_element?()
      assert view |> element("input[type=time][value='08:15']") |> has_element?()
    end
  end

  describe "tabs and modals" do
    test "a tab button shows its tab" do
      {view, _html} =
        start(
          surface("main", [
            %{
              "id" => "root",
              "component" => "Tabs",
              "tabs" => [
                %{"title" => "First", "child" => "a"},
                %{"title" => "Second", "child" => "b"}
              ]
            },
            %{"id" => "a", "component" => "Text", "text" => "first body"},
            %{"id" => "b", "component" => "Text", "text" => "second body"}
          ])
        )

      assert render(view) =~ "first body"
      assert view |> element("[role=tab][aria-selected=true]", "First") |> has_element?()

      html = view |> element("[role=tab]", "Second") |> render_click()
      assert html =~ "second body"
      refute html =~ "first body"
    end

    test "the modal sample opens from its button, which also acts, and closes" do
      [bundle] =
        for {"v1.0", file} <- Reference.bundle_files(),
            String.ends_with?(file, "36_modal.json"),
            do: file

      {view, html} = start(bundle |> File.read!() |> Jason.decode!() |> Map.fetch!("messages"))

      refute html =~ "This is the content inside the modal."

      view |> element("button", "Open Modal") |> render_click()
      assert view |> element("[role=dialog][aria-modal=true]") |> render() =~ "inside the modal"
      assert %{"action" => %{"name" => "openModalEvent"}} = sent()

      view |> element("button[aria-label=Close]") |> render_click()
      refute render(view) =~ "inside the modal"
    end
  end

  describe "accessibility" do
    test "explicit attributes reach the markup" do
      {view, _html} =
        start(
          surface(
            "main",
            [
              %{"id" => "root", "component" => "Column", "children" => ["go", "status", "icon"]},
              %{"id" => "go_text", "component" => "Text", "text" => "Go"},
              %{
                "id" => "go",
                "component" => "Button",
                "child" => "go_text",
                "action" => %{"event" => %{"name" => "go"}},
                "accessibility" => %{
                  "label" => "Start the search",
                  "description" => "Runs it now"
                }
              },
              %{
                "id" => "status",
                "component" => "Text",
                "text" => "Ready",
                "accessibility" => %{"live" => "polite", "hidden" => %{"@path" => "/hide"}}
              },
              %{"id" => "icon", "component" => "Icon", "name" => "mail"}
            ],
            %{"hide" => true}
          )
        )

      assert view
             |> element("button[aria-label='Start the search'][aria-description='Runs it now']")
             |> has_element?()

      assert view
             |> element("[data-a2ui-id=status][aria-live=polite][aria-hidden=true]")
             |> has_element?()

      assert view |> element("i.material-icons[aria-hidden=true]", "mail") |> has_element?()
      refute view |> element("[data-a2ui-id=go_text][aria-label]") |> has_element?()
    end

    test "inputs are labelled and described by their errors" do
      {view, _html} =
        start(
          surface(
            "main",
            [
              %{
                "id" => "root",
                "component" => "TextField",
                "label" => "Code",
                "value" => %{"@path" => "/code"},
                "checks" => [
                  %{
                    "condition" => %{
                      "@call" => "required",
                      "args" => %{"value" => %{"@path" => "/code"}}
                    },
                    "message" => "Required."
                  }
                ]
              }
            ],
            %{"code" => ""}
          )
        )

      html = render(view)
      [_, input_id] = Regex.run(~r/<label for="([^"]+)"/, html)
      assert view |> element("input##{input_id}[aria-invalid=true]") |> has_element?()
      [_, described_by] = Regex.run(~r/aria-describedby="([^"]+)"/, html)
      assert view |> element("##{described_by}", "Required.") |> has_element?()
    end
  end

  describe "openUrl" do
    test "a function-call action pushes the URL to the browser" do
      {view, _html} =
        start(
          surface(
            "main",
            [
              %{
                "id" => "root",
                "component" => "Button",
                "child" => "t",
                "action" => %{
                  "functionCall" => %{
                    "@call" => "openUrl",
                    "args" => %{"url" => %{"@path" => "/link"}}
                  }
                }
              },
              %{"id" => "t", "component" => "Text", "text" => "Docs"}
            ],
            %{"link" => "https://a2ui.org"}
          )
        )

      view |> element("button", "Docs") |> render_click()
      assert_push_event(view, "a2ui:open_url", %{url: "https://a2ui.org"})
      refute_receive {:sent, _}
    end
  end

  describe "hosting" do
    test "a failed agent message is reported to the agent" do
      {view, _html} = start([create("main")])

      send(view.pid, {:agent, components("main", [%{"id" => "root"}])})

      assert_receive {:handled, {:error, %A2UICore.Error{code: "VALIDATION_FAILED"}}}

      assert %{"error" => %{"code" => "VALIDATION_FAILED", "surfaceId" => "main", "path" => "/"}} =
               sent()
    end

    test "a request about a node that is gone is dropped" do
      {view, _html} =
        start(surface("main", [%{"id" => "root", "component" => "Text", "text" => "Still here"}]))

      send(view.pid, {A2UIPhoenix.Surface, "main", {:invoke, 999, "action"}})
      send(view.pid, {A2UIPhoenix.Surface, "main", {:write, 999, "value", "x"}})

      assert render(view) =~ "Still here"
      refute_receive {:sent, _}
    end

    test "without callbacks, effects are dropped" do
      {view, _html} =
        start(
          surface("main", [
            %{
              "id" => "root",
              "component" => "Button",
              "child" => "t",
              "action" => %{"event" => %{"name" => "go"}}
            },
            %{"id" => "t", "component" => "Text", "text" => "Go"}
          ]),
          %{"silent" => true}
        )

      view |> element("button", "Go") |> render_click()
      assert render(view) =~ "Go"
      refute_receive {:sent, _}
    end

    test "events about unknown nodes or with bad values are ignored" do
      {view, _html} =
        start(
          surface("main", [
            %{
              "id" => "root",
              "component" => "Tabs",
              "tabs" => [%{"title" => "One", "child" => "a"}]
            },
            %{"id" => "a", "component" => "Text", "text" => "body"}
          ])
        )

      target = element(view, "#surface-main-form")

      render_change(target, %{
        "_target" => ["a2ui", "999", "value"],
        "a2ui" => %{"999" => %{"value" => "x"}}
      })

      render_change(target, %{
        "_target" => ["a2ui", "nan", "value"],
        "a2ui" => %{"nan" => %{"value" => "x"}}
      })

      render_submit(target, %{})

      assert render(view) =~ "body"
      refute_receive {:sent, _}
    end

    test "Live needs init/3" do
      assert_raise ArgumentError, ~r/init\/3 was not called/, fn ->
        A2UIPhoenix.Live.session(bare_socket())
      end
    end
  end

  describe "example bundles" do
    bundles = Reference.bundle_files()

    if Reference.required?() do
      test "the reference examples were found" do
        assert length(unquote(Macro.escape(bundles))) == 86
      end
    end

    for {version, file} <- bundles do
      name = Path.basename(file)

      test "#{version} #{name} renders" do
        messages = unquote(file) |> File.read!() |> Jason.decode!() |> Map.fetch!("messages")
        {view, _html} = start(messages)
        html = render(view)

        refute html =~ "a2ui-unknown_type"
        refute html =~ "a2ui-unrendered"
        refute_receive {:sent, %{"error" => _}}

        for %{"updateComponents" => %{"surfaceId" => id, "components" => components}} <- messages,
            Enum.any?(components, &(&1["id"] == "root")) do
          assert view |> element("#surface-#{id} [data-a2ui-id=root]") |> has_element?()
        end
      end
    end
  end
end

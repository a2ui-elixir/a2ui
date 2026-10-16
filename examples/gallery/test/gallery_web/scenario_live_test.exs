defmodule GalleryWeb.ScenarioLiveTest do
  use GalleryWeb.ConnCase, async: true

  test "the index lists every scenario", %{conn: conn} do
    {:ok, _view, html} = live(conn, "/")

    for scenario <- Gallery.Scenario.all() do
      assert html =~ scenario.title()
      assert html =~ ~s(href="/scenarios/#{scenario.id()}")
    end
  end

  test "an unknown scenario is not found", %{conn: conn} do
    assert_error_sent 404, fn -> get(conn, "/scenarios/nope") end
  end

  test "components: the tabs show every component, and buttons reach the agent", %{conn: conn} do
    {:ok, view, html} = live(conn, "/scenarios/components")
    assert html =~ "The basic catalog"

    view |> element("#frame-gallery [role=tab]", "Buttons and dialogs") |> render_click()
    press(view, "gallery", "Primary")
    eventually_in(view, "#frame-gallery", "The agent saw the primary button.")
  end

  test "forms: the button waits for valid input; the reply swaps the form", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/scenarios/forms")
    assert has_element?(view, "#frame-signup button[disabled]", "Create account")

    control(view, "fill")

    eventually(view, fn _html ->
      not has_element?(view, "#frame-signup button[disabled]", "Create account")
    end)

    press(view, "signup", "Create account")
    eventually_in(view, "#frame-signup", "Welcome, Ada Lovelace!")

    press(view, "signup", "Edit my details")
    eventually_in(view, "#frame-signup", "Your details are as you left them.")
  end

  test "data: templates, formatting, live quotes and data-model updates", %{conn: conn} do
    {:ok, view, html} = live(conn, "/scenarios/data")
    assert html =~ "3 stocks, prices in EUR."
    assert html =~ ~r{class="a2ui-text a2ui-text-caption"[^>]*>#3</span>}
    assert html =~ ~r/€\d{2,3}\.\d\d/
    assert html =~ "Volume 1,204,331"

    # The agent pushes a quote and a time every tick.
    eventually(view, &(not (&1 =~ "Updated at 09:30:00 UTC")))

    control(view, "add")
    eventually_in(view, "#frame-market", "4 stocks, prices in EUR.")
    assert has_element?(view, "#frame-market", "HOOL")

    control(view, "usd")
    eventually(view, &(&1 =~ "prices in USD" and &1 =~ ~r/\$\d{2,3}\.\d\d/))

    note = "#frame-market [data-a2ui-id=note]"
    control(view, "delete_note")
    eventually(view, fn _html -> not has_element?(view, note, "Quotes are simulated") end)
    assert has_element?(view, "#log .ui-log-entry", "MISSING_DATA_BINDING")

    control(view, "reset")
    eventually(view, fn _html -> has_element?(view, note, "Quotes are simulated") end)
    assert has_element?(view, "#frame-market", "3 stocks, prices in EUR.")
    refute has_element?(view, "#frame-market", "HOOL")
  end

  test "surfaces: a second surface comes and goes; components change", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/scenarios/surfaces")

    press(view, "inbox", "Write a message")
    eventually(view, fn _html -> has_element?(view, "#frame-compose") end)
    assert has_element?(view, "#frame-compose button[disabled]", "Send")

    type(view, "compose", "subject", "Lunch")
    press(view, "compose", "Send")
    eventually_in(view, "#frame-inbox", "4 messages.")
    assert has_element?(view, "#frame-inbox", "Lunch")
    refute has_element?(view, "#frame-compose")

    press(view, "inbox", "What is A2UI?")
    assert_push_event(view, "a2ui:open_url", %{url: "https://a2ui.org"})

    control(view, "notice")
    eventually_in(view, "#frame-notice", "The office closes early on Friday.")
    press(view, "notice", "Dismiss")
    eventually(view, fn _html -> not has_element?(view, "#frame-notice") end)

    control(view, "footer")
    eventually_in(view, "#frame-inbox", "Messages older than 30 days are archived.")
    control(view, "retitle")
    eventually_in(view, "#frame-inbox", "Inbox (updated by the agent)")
    control(view, "cards")

    eventually(view, fn _html ->
      has_element?(view, "#frame-inbox [data-a2ui-id=message].a2ui-card")
    end)
  end

  test "functions: agent calls, their answers, errors and timeouts", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/scenarios/functions")

    eventually_in(view, "#frame-functions", "Paris")
    eventually_in(view, "#frame-functions", "A table for 2 is free on Saturday at 19:30.")
    eventually_shows(view, "timed out after 400ms")

    type(view, "functions", "zip", "99999")
    eventually_shows(view, "No city has the postcode 99999.")

    press(view, "functions", "Reserve a table")
    eventually_in(view, "#frame-functions", "Reserved for 2 near")

    control(view, "info")
    eventually_in(view, "#said", "You are in")
    control(view, "renderer_only")
    eventually_shows(view, "allowedCallers is rendererOnly")
    control(view, "unknown")
    eventually_shows(view, "Function not found: teleport")
    control(view, "bad_args")
    eventually_shows(view, "Unevaluated properties are not allowed")
  end

  test "custom catalogs: the gallery's components and function", %{conn: conn} do
    {:ok, view, html} = live(conn, "/scenarios/custom")
    assert html =~ ~s(class="widget-badge widget-badge-info")
    assert html =~ ">GH</span>"
    assert html =~ ~s(<span class="widget-progress-label">Sprint</span>)
    assert html =~ ~s(<span class="widget-progress-value">42 %</span>)
    assert html =~ "12 tasks done."
    assert html =~ ~s(class="restaurant-rating")

    control(view, "rename")
    eventually_in(view, "#frame-team .widget-badge", "DV")

    control(view, "advance")
    eventually(view, &(&1 =~ ">80 %</span>" and &1 =~ "15 tasks done."))
  end

  test "streaming: the surface builds while the answer arrives", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/scenarios/streaming")

    eventually_shows(view, "like to know?")
    assert has_element?(view, "#frame-forecast", "Clouds build on Wednesday")
    assert has_element?(view, "#frame-forecast", "Lisbon, this week")

    control(view, "express")
    eventually_shows(view, "An Express answer is read when it is complete.")
    eventually(view, fn _html -> has_element?(view, "#frame-forecast") end)
  end

  describe "mcp" do
    test "tools write the surface and open an app", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/scenarios/mcp")

      press(view, "travel", "Get the weather")
      eventually_in(view, "#frame-travel", "Lisbon: sunny, 24 °C.")

      press(view, "travel", "Open the trip dashboard")

      eventually(view, fn _html ->
        has_element?(view, "[phx-hook=A2UIMcpApp][data-html*='Trip dashboard']")
      end)
    end

    test "the app's requests reach the surface and the agent", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/scenarios/mcp")
      app = element(view, "[phx-hook=A2UIMcpApp]")
      [_, ref] = Regex.run(~r/data-ref="(\d+)"/, render(app))

      request = fn method, params, id ->
        render_hook(app, "a2ui:mcp_app", %{
          "ref" => ref,
          "method" => method,
          "params" => params,
          "id" => id
        })
      end

      request.("tools/call", %{"name" => "get_weather", "arguments" => %{"city" => "Rome"}}, 1)

      assert_push_event(view, "a2ui:mcp_app:reply", %{
        id: 1,
        result: %{"structuredContent" => %{"sky" => "sunny"}}
      })

      eventually_in(view, "#said", "The dashboard checked the weather in Rome.")

      request.("tools/call", %{"name" => "delete_trip", "arguments" => %{}}, 2)

      assert_push_event(view, "a2ui:mcp_app:reply", %{
        id: 2,
        error: %{message: "Tool 'delete_trip' is not allowed."}
      })

      request.(
        "ui/requests/function-call",
        %{"call" => "formatString", "args" => %{"value" => "${/trip/city}"}},
        3
      )

      assert_push_event(view, "a2ui:mcp_app:reply", %{id: 3, result: %{"result" => "Lisbon"}})

      request.(
        "ui/notifications/data-model-change",
        %{"key" => "trip", "subpath" => "/days", "value" => 5},
        nil
      )

      eventually_in(view, "#frame-travel", "Planned: 5 days in Lisbon.")

      request.(
        "ui/message",
        %{"role" => "user", "content" => [%{"type" => "text", "text" => "Ideas?"}]},
        4
      )

      eventually_in(view, "#frame-travel", "Ideas: tile museum")
    end
  end

  describe "errors" do
    for {control, expected} <- [
          {"duplicate", "INTEGRITY_ERROR"},
          {"invalid", "VALIDATION_FAILED at /components/0/text"},
          {"cycle", "RECURSION_LIMIT"},
          {"catalog", "CATALOG_ERROR"},
          {"version", "CATALOG_ERROR"},
          {"unsupported", "UNSUPPORTED_VERSION"},
          {"reserved", "VALIDATION_FAILED"}
        ] do
      test "#{control} is rejected and reported", %{conn: conn} do
        {:ok, view, _html} = live(conn, "/scenarios/errors")
        control(view, unquote(control))
        eventually_in(view, "#frame-main", "Last error reported: " <> unquote(expected))
      end
    end

    test "the agent recovers from an update to a missing surface", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/scenarios/errors")
      control(view, "ghost")
      eventually_in(view, "#frame-ghost", "created on the second try")
    end

    test "a child sent later fills its placeholder", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/scenarios/errors")
      control(view, "missing_child")
      eventually_in(view, "#frame-main", "I arrived a moment later.")
    end

    test "problems found while resolving are diagnostics", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/scenarios/errors")
      control(view, "unknown_type")
      eventually_shows(view, "UNKNOWN_COMPONENT_TYPE")
      control(view, "passive")
      eventually_shows(view, "requires user activation context to execute")
      control(view, "failing")
      eventually_shows(view, "Cannot convert to number")
    end
  end

  test "v0.9: a themed surface, boolean checks and the data model on actions", %{conn: conn} do
    {:ok, view, html} = live(conn, "/scenarios/v0_9")
    assert html =~ "--a2ui-color-primary: #7048e8"
    assert html =~ "Library assistant"

    assert has_element?(
             view,
             "#frame-library .a2ui-surface-attribution img[src$='/media/avatar.svg']"
           )

    type(view, "library", "reader", "123456")

    eventually(view, fn _html ->
      has_element?(view, "#frame-library button:not([disabled])", "Borrow")
    end)

    # The first book's button: every row of the template has one.
    [_, first] = Regex.run(~r/data-a2ui-id="borrow" id="([^"]+)"/, render(view))
    view |> element("#" <> first) |> render_click()
    eventually_in(view, "#frame-library", "is yours for three weeks.")
    assert has_element?(view, "#said", "Card 123456 borrows")

    control(view, "return")
    eventually_in(view, "#frame-library", "Every book is back on the shelf.")
  end
end

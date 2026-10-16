defmodule GalleryWeb.ExamplesLiveTest do
  use GalleryWeb.ConnCase, async: true

  bundles = GalleryWeb.ExamplesLive.bundles()

  if bundles == [] and System.get_env("A2UI_REQUIRE_REFERENCE") == "1" do
    test "the reference checkout is there" do
      flunk("No reference examples: clone reference/a2ui or set A2UI_REFERENCE_ROOT.")
    end
  end

  if bundles != [] do
    test "the page lists every example and opens the first", %{conn: conn} do
      {:ok, view, html} = live(conn, "/examples")
      assert html =~ "Complex Layout"
      assert has_element?(view, ".examples nav a.active", "Complex Layout")
      assert length(Regex.scan(~r/href="\/examples\//, html)) == unquote(length(bundles))
    end

    test "an example's action is listed, since no agent is there", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/examples/00_interactive-button")
      view |> element(".surface-frame button", "Click Me") |> render_click()
      assert has_element?(view, "#notes .note-action", "button_clicked")
    end
  end

  for bundle <- bundles do
    @name bundle.name

    test "#{bundle.name} renders without errors", %{conn: conn} do
      {:ok, view, html} = live(conn, "/examples/" <> @name)
      assert has_element?(view, ".surface-frame .a2ui-surface")
      refute html =~ "a2ui-placeholder"
      refute has_element?(view, "#notes .note-rejected")
      refute has_element?(view, "#notes .note-error")
    end
  end
end

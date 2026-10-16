defmodule GalleryWeb.ConnCase do
  @moduledoc """
  Tests of the gallery's pages, with `Phoenix.LiveViewTest` and helpers
  for the agents' delayed answers and the surfaces' inputs.
  """

  use ExUnit.CaseTemplate

  import Phoenix.LiveViewTest

  using do
    quote do
      @endpoint GalleryWeb.Endpoint

      import Phoenix.ConnTest
      import Phoenix.LiveViewTest
      import GalleryWeb.ConnCase
    end
  end

  setup _tags, do: {:ok, conn: Phoenix.ConnTest.build_conn()}

  @doc """
  Renders `view` until `check` holds for the HTML, failing with the last
  render after `timeout` milliseconds. Agents answer after a delay.
  """
  def eventually(view, check, timeout \\ 3_000) do
    deadline = System.monotonic_time(:millisecond) + timeout
    wait(view, check, deadline)
  end

  defp wait(view, check, deadline) do
    html = render(view)

    cond do
      check.(html) ->
        html

      System.monotonic_time(:millisecond) > deadline ->
        ExUnit.Assertions.flunk("The page never got there. Last render:\n" <> html)

      true ->
        Process.sleep(20)
        wait(view, check, deadline)
    end
  end

  @doc "Waits until the page shows `text` anywhere (the message log included)."
  def eventually_shows(view, text, timeout \\ 3_000),
    do: eventually(view, &(&1 =~ text), timeout)

  @doc "Waits until an element matching `selector` shows `text`."
  def eventually_in(view, selector, text, timeout \\ 3_000),
    do:
      eventually(
        view,
        fn _html -> Phoenix.LiveViewTest.has_element?(view, selector, text) end,
        timeout
      )

  @doc "The node reference of input `component_id` (its form field name)."
  def input_ref(view, surface_id, component_id, field \\ "value") do
    html = view |> element("#frame-#{surface_id} [data-a2ui-id='#{component_id}']") |> render()
    [_, ref] = Regex.run(~r/name="a2ui\[(\d+)\]\[#{field}\]/, html)
    ref
  end

  @doc "Types `value` into input `component_id` of surface `surface_id`."
  def type(view, surface_id, component_id, value, field \\ "value") do
    ref = input_ref(view, surface_id, component_id, field)

    view
    |> element("#surface-#{surface_id}-form")
    |> render_change(%{"_target" => ["a2ui", ref, field], "a2ui" => %{ref => %{field => value}}})
  end

  @doc "Presses the button of surface `surface_id` labelled `label`."
  def press(view, surface_id, label) do
    view |> element("#frame-#{surface_id} button", label) |> render_click()
  end

  @doc "The DOM ids of the elements matching `selector` whose text has `text`, in order."
  def ids_of(view, selector, text) do
    view
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.query(selector)
    |> Enum.filter(&(LazyHTML.text(&1) =~ text))
    |> Enum.flat_map(&LazyHTML.attribute(&1, "id"))
  end

  @doc "Presses the page control `id`."
  def control(view, id), do: view |> element("button[phx-value-id='#{id}']") |> render_click()
end

defmodule GalleryWeb.ChatLiveTest do
  # A conversation with the restaurant agent over A2A, the agent served
  # by Bandit on a free port.
  use GalleryWeb.ConnCase, async: false

  setup_all do
    {:ok, server} =
      start_supervised(
        {Bandit, plug: RestaurantAgent.Router, ip: {127, 0, 0, 1}, port: 0, startup_log: false}
      )

    {:ok, {_ip, port}} = ThousandIsland.listener_info(server)
    url = "http://127.0.0.1:#{port}"

    previous =
      {Application.get_env(:gallery, :agent_url),
       Application.get_env(:restaurant_agent, :public_url)}

    Application.put_env(:gallery, :agent_url, url)
    Application.put_env(:restaurant_agent, :public_url, url)

    on_exit(fn ->
      {agent_url, public_url} = previous
      Application.put_env(:gallery, :agent_url, agent_url)
      Application.put_env(:restaurant_agent, :public_url, public_url)
    end)

    %{url: url}
  end

  test "a conversation that books a table", %{conn: conn, url: url} do
    {:ok, view, _html} = live(conn, "/chat")
    assert has_element?(view, "#chat-head", "Restaurant finder")
    assert has_element?(view, "#chat-head", url)

    view |> element("#suggestions button", "Find Italian restaurants") |> render_click()
    eventually_in(view, "#transcript", "Trattoria Roma")
    assert has_element?(view, "#transcript .rating")

    [book | _] = ids_of(view, "#transcript button", "Book a table")
    view |> element("#" <> book) |> render_click()

    # The form asks the agent whether a table is free (callAgentFunction)
    # and the agent asks the renderer for its time zone (callRendererFunction).
    eventually_in(view, "#transcript", "Book a table at Trattoria Roma")
    eventually_in(view, "#transcript", "A table for 2 is free at 19:30.")
    eventually(view, &(&1 =~ ~r/Times are in [A-Za-z_\/+-]+\./))

    [_, booking] = Regex.run(~r/id="frame-(booking[^"]*)"/, render(view))
    type(view, booking, "root__name", "Ada Lovelace")
    type(view, booking, "root__email", "ada@example.com")
    press(view, booking, "Confirm booking")

    eventually_in(view, "#transcript", "Table booked")
    assert has_element?(view, "#transcript", "Ada Lovelace, we expect you at Trattoria Roma")
    assert has_element?(view, "#log .log-entry", "rendererFunctionResponse")
    assert has_element?(view, "#log .log-entry", "agentFunctionResponse")
  end

  test "typing a message works like a suggestion", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/chat")
    view |> form("#composer", %{"text" => "Something Japanese, please"}) |> render_submit()
    assert has_element?(view, "#transcript .bubble.user", "Something Japanese, please")
    eventually_in(view, "#transcript", "Japanese restaurants near you")
  end

  test "an agent that does not answer is reported", %{conn: conn, url: url} do
    Application.put_env(:gallery, :agent_url, "http://127.0.0.1:9")
    on_exit(fn -> Application.put_env(:gallery, :agent_url, url) end)

    {:ok, view, _html} = live(conn, "/chat")
    assert has_element?(view, ".problem", "does not answer")
    assert has_element?(view, "#composer input[disabled]")
  end
end

defmodule TerminalClient.ChatTest do
  # The terminal client against the restaurant agent, served by Bandit on
  # a free port, over every transport.
  use ExUnit.Case, async: true

  alias TerminalClient.Chat

  @booking [
    "Find Italian restaurants",
    "click:Book a table#1",
    "type:Your name=Ada",
    "type:Email=ada@example.com",
    "click:Confirm booking",
    "click:Done"
  ]

  setup do
    {:ok, server} =
      start_supervised(
        {Bandit, plug: RestaurantAgent.Router, ip: {127, 0, 0, 1}, port: 0, startup_log: false}
      )

    {:ok, {_ip, port}} = ThousandIsland.listener_info(server)
    %{url: "http://127.0.0.1:#{port}"}
  end

  # Runs the steps and returns what the terminal showed.
  defp chat(url, options, steps) do
    test = self()
    print = fn line -> send(test, {:line, line}) end
    {:ok, chat} = Chat.connect([url: url, print: print] ++ options)
    result = Chat.run(chat, Enum.map(steps, &Chat.parse/1))
    {result, lines()}
  end

  defp lines(acc \\ []) do
    receive do
      {:line, line} -> lines([line | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  # The availability line: the agent function's answer, after its icon.
  defp free?(lines),
    do: Enum.any?(lines, &String.ends_with?(&1, "A table for 2 is free at 19:30."))

  defp booked?(lines) do
    "agent: Done! Your table at Pizzeria Napoli is booked." in lines and
      "Ada, we expect you at Pizzeria Napoli on Saturday, October 17 at 19:30." in lines and
      "agent: Enjoy your meal!" in lines and
      Enum.any?(lines, &String.match?(&1, ~r/\A\(booking-.+ closed\)\z/))
  end

  test "A2A message/send: the whole booking, with the agent function and clientInfo", %{url: url} do
    {{:ok, _chat}, lines} = chat(url, [transport: "a2a"], @booking)

    assert "agent: Here are 3 places. Pick one to book a table." in lines
    assert Enum.any?(lines, &(&1 =~ ~r/\A│ ★★★★★ 4\.8 · 1033 reviews +│\z/))
    assert Enum.any?(lines, &String.ends_with?(&1, " …"))
    assert free?(lines)
    assert Enum.any?(lines, &String.starts_with?(&1, "agent: Times are in "))
    assert booked?(lines)
  end

  test "A2A message/stream", %{url: url} do
    {{:ok, _chat}, lines} = chat(url, [transport: "a2a", stream: true], @booking)
    assert booked?(lines)
  end

  test "A2A with the model writing Express", %{url: url} do
    {{:ok, _chat}, lines} = chat(url, [transport: "express"], @booking)
    assert Enum.any?(lines, &(&1 =~ "★★★★★ 4.8"))
    refute free?(lines)
    assert booked?(lines)
  end

  test "protocol v0.9 over A2A", %{url: url} do
    {{:ok, _chat}, lines} = chat(url, [transport: "a2a", version: "v0.9"], @booking)
    assert "— Restaurant finder —" in lines
    assert booked?(lines)
  end

  test "WebSocket", %{url: url} do
    {{:ok, _chat}, lines} = chat(url, [transport: "ws"], @booking)
    assert free?(lines)
    assert booked?(lines)
  end

  test "MCP and AG-UI carry the actions, and no function calls", %{url: url} do
    for transport <- ["mcp", "agui"] do
      {{:ok, _chat}, lines} = chat(url, [transport: transport], @booking)
      refute Enum.any?(lines, &String.ends_with?(&1, " …"))
      assert booked?(lines), "#{transport}: #{Enum.join(lines, "\n")}"
    end
  end

  test "server-sent events show the list, and carry nothing back", %{url: url} do
    {{:error, "Nothing labelled \"Your name\" on screen.", _chat}, lines} =
      chat(url, [transport: "sse"], @booking)

    assert "ITALIAN RESTAURANTS NEAR YOU" in lines
    assert "(sse does not carry action back to the agent)" in lines
  end

  test "an agent that is not there" do
    {:ok, chat} = Chat.connect(url: "http://127.0.0.1:1", print: fn _line -> :ok end)
    assert {:error, _reason, _chat} = Chat.run(chat, [{:say, "hello"}])
  end

  test "steps from the command line" do
    assert Chat.parse("click:Book a table#2") == {:click, "Book a table", 2}
    assert Chat.parse("click:Done") == {:click, "Done"}
    assert Chat.parse("type:Your name=Ada = Lovelace") == {:type, "Your name", "Ada = Lovelace"}
    assert Chat.parse("hello") == {:say, "hello"}
  end
end

defmodule Gallery.Scenarios.Functions do
  @moduledoc """
  Functions on both sides of the wire (protocol v1.0).

  The renderer sends the agent the calls it cannot run itself: a
  function no catalog of the surface declares (`lookupCity`), and one a
  catalog declares for the agent to run (`checkAvailability` in the
  restaurant catalog). The text that uses such a call is busy until the
  agent's `agentFunctionResponse` arrives, and a call the agent never
  answers times out. A button's function-call action calls the agent on
  every press. The agent, in turn, calls renderer functions with
  `callRendererFunction`: one it may call, one only the renderer may
  call, one that does not exist and one with arguments the catalog
  refuses.
  """

  use Gallery.Scenario

  @restaurant "https://example.com/a2ui/catalogs/restaurant/v1/catalog.json"
  @basic "https://a2ui.org/specification/v1_0/catalogs/basic/catalog.json"

  @cities %{
    "75001" => "Paris",
    "10115" => "Berlin",
    "1100" => "Lisbon",
    "00184" => "Rome",
    "28013" => "Madrid",
    "1011" => "Amsterdam"
  }

  def id, do: "functions"
  def title, do: "Functions and RPC"

  def summary,
    do:
      "Calls the renderer sends to the agent (callAgentFunction), their answers, errors and timeouts, and calls the agent sends to the renderer (callRendererFunction)."

  def features,
    do: [
      "callAgentFunction",
      "agentFunctionResponse",
      "busy state",
      "TIMEOUT",
      "function-call action",
      "callRendererFunction",
      "rendererFunctionResponse",
      "allowedCallers",
      "INVALID_FUNCTION_CALL",
      "catalogId on a call"
    ]

  # Agent calls time out after five seconds (`:agent_timeout_ms`).
  def session_options,
    do: [default_timeout_ms: Application.get_env(:gallery, :agent_timeout_ms, 5_000)]

  def messages do
    [
      create("functions",
        data: %{
          "zip" => "75001",
          "people" => 2,
          "date" => "2026-10-17T19:30",
          "reservation" => "",
          "client" => ""
        },
        components: surface()
      )
    ]
  end

  defp surface do
    [
      %{
        "id" => "root",
        "component" => "Column",
        "children" => ["title", "intro", "cityCard", "tableCard", "slowCard", "actions", "client"]
      },
      text("title", "## Functions"),
      text(
        "intro",
        "The renderer runs the basic catalog's functions. It sends the others to the agent, " <>
          "and the text stays busy until the answer comes. Try 10115, 1100 or 99999.",
        %{"variant" => "caption"}
      )
    ] ++
      demo(
        "city",
        "Look up a city",
        "lookupCity: no catalog declares it, so the call goes to the agent.",
        [
          %{
            "id" => "zip",
            "component" => "TextField",
            "label" => "Postcode",
            "value" => path("/zip")
          },
          answer(
            "cityLine",
            "locationOn",
            text("city", call("lookupCity", %{"zip" => path("/zip")}), %{
              "accessibility" => %{"label" => "City", "live" => "polite"}
            })
          )
        ]
      ) ++
      demo(
        "table",
        "Check a table",
        "checkAvailability: the restaurant catalog declares it for the agent to run.",
        [
          %{
            "id" => "people",
            "component" => "Slider",
            "label" => "People",
            "min" => 1,
            "max" => 12,
            "value" => path("/people")
          },
          answer(
            "tableLine",
            "event",
            text(
              "availability",
              %{
                "@call" => "checkAvailability",
                "catalogId" => @restaurant,
                "args" => %{
                  "restaurantId" => "lisboa",
                  "date" => path("/date"),
                  "partySize" => path("/people")
                }
              },
              %{"accessibility" => %{"live" => "polite"}}
            )
          )
        ]
      ) ++
      demo(
        "slow",
        "Wait for an answer",
        "slowEstimate: the agent never answers, so the call times out.",
        [
          answer(
            "slowLine",
            "refresh",
            text(
              "estimate",
              call("formatString", %{"value" => "Waiting time: ${slowEstimate()}"})
            )
          )
        ]
      ) ++
      [
        %{
          "id" => "actions",
          "component" => "Row",
          "align" => "center",
          "children" => ["reserve", "reservation"]
        }
      ] ++
      button(
        "reserve",
        "Reserve a table",
        %{
          "functionCall" =>
            call("reserveTable", %{"zip" => path("/zip"), "people" => path("/people")})
        },
        %{"variant" => "primary"}
      ) ++
      [
        text("reservation", path("/reservation"), %{"weight" => 1}),
        text("client", path("/client"), %{"variant" => "caption"})
      ]
  end

  # A card that shows one function: its name and what it does, then the
  # components that use it.
  defp demo(id, title, about, body) do
    body = List.flatten(body)

    [
      %{"id" => id <> "Card", "component" => "Card", "child" => id <> "Body"},
      %{
        "id" => id <> "Body",
        "component" => "Column",
        "children" => [id <> "Title", id <> "About" | Enum.map(top_level(body), & &1["id"])]
      },
      text(id <> "Title", "#### " <> title),
      text(id <> "About", about, %{"variant" => "caption"})
    ] ++ body
  end

  # A result line: an icon, then the text that shows the answer.
  defp answer(id, icon, line) do
    [
      %{
        "id" => id,
        "component" => "Row",
        "align" => "center",
        "children" => [id <> "Icon", line["id"]]
      },
      %{"id" => id <> "Icon", "component" => "Icon", "name" => icon},
      Map.put(line, "weight", 1)
    ]
  end

  # The components a demo lists as its own children: the first of each
  # group (a field, or an answer's row).
  defp top_level(components) do
    nested =
      for %{"children" => children} <- components,
          is_list(children),
          child <- children,
          into: MapSet.new(),
          do: child

    Enum.reject(components, &MapSet.member?(nested, &1["id"]))
  end

  # -- calls from the renderer ------------------------------------------------------

  def reply(%{"callAgentFunction" => %{"functionCallId" => id, "callFunction" => call}}) do
    agent_function(id, call["@call"], call["args"] || %{})
  end

  def reply(%{"rendererFunctionResponse" => %{"functionCallId" => "info"} = response}) do
    case response do
      %{"value" => %{"timeZone" => zone, "locale" => locale}} ->
        [
          {200, {:text, "You are in #{zone}, and read #{locale}."}},
          {200, data("functions", "/client", "Renderer: #{zone}, #{locale}.")}
        ]

      %{"error" => error} ->
        [{200, {:text, "The renderer refused: #{error["message"]}"}}]
    end
  end

  def reply(%{"rendererFunctionResponse" => %{"error" => error}}),
    do: [{200, {:text, "The renderer answered with #{error["code"]}: #{error["message"]}"}}]

  def reply(%{"rendererFunctionResponse" => %{"value" => value}}),
    do: [{200, {:text, "The renderer answered #{Jason.encode!(value)}."}}]

  def reply(_message), do: []

  defp agent_function(id, "lookupCity", %{"zip" => zip}) do
    case Map.fetch(@cities, String.trim(to_string(zip))) do
      {:ok, city} ->
        [{700, response(id, %{"value" => city})}]

      :error ->
        [
          {700,
           response(id, %{
             "error" => %{
               "code" => "EXECUTION_ERROR",
               "message" => "No city has the postcode #{zip}."
             }
           })}
        ]
    end
  end

  defp agent_function(id, "checkAvailability", %{"partySize" => size})
       when is_number(size) and size > 8,
       do: [{500, response(id, %{"value" => "No table for #{trunc(size)} on Saturday, sorry."})}]

  defp agent_function(id, "checkAvailability", %{"partySize" => size}) when is_number(size),
    do: [
      {500,
       response(id, %{"value" => "A table for #{trunc(size)} is free on Saturday at 19:30."})}
    ]

  # The agent never answers: the renderer gives up after the timeout.
  defp agent_function(_id, "slowEstimate", _args), do: []

  defp agent_function(id, "reserveTable", args) do
    code = "R-#{:erlang.phash2({args, System.os_time()}, 9000) + 1000}"
    city = Map.get(@cities, to_string(args["zip"]), "your area")

    [
      {600,
       [
         response(id, %{"value" => code}),
         data(
           "functions",
           "/reservation",
           "Reserved for #{args["people"]} near #{city}: #{code}."
         )
       ]}
    ]
  end

  defp agent_function(id, name, _args),
    do: [
      {300,
       response(id, %{
         "error" => %{
           "code" => "UNKNOWN_FUNCTION",
           "message" => "The agent has no function #{name}."
         }
       })}
    ]

  defp response(id, outcome),
    do: %{"version" => "v1.0", "agentFunctionResponse" => Map.put(outcome, "functionCallId", id)}

  # -- calls from the agent ------------------------------------------------------------

  def controls,
    do: [
      {"info", "Agent calls clientInfo"},
      {"renderer_only", "Agent calls formatString (renderer only)"},
      {"unknown", "Agent calls teleport (unknown)"},
      {"bad_args", "Agent calls clientInfo with bad arguments"}
    ]

  def control("info"), do: [{100, renderer_call("info", "clientInfo", %{}, @restaurant)}]

  # The basic catalog's functions default to allowedCallers rendererOnly.
  def control("renderer_only"),
    do: [
      {100, renderer_call("renderer_only", "formatString", %{"value" => "Hi ${/zip}"}, @basic)}
    ]

  def control("unknown"),
    do: [{100, renderer_call("unknown", "teleport", %{"to" => "Mars"}, @basic)}]

  def control("bad_args"),
    do: [{100, renderer_call("bad_args", "clientInfo", %{"verbose" => true}, @restaurant)}]

  def control(_id), do: []

  defp renderer_call(id, name, args, catalog_id) do
    function_call = %{"@call" => name, "catalogId" => catalog_id, "args" => args}

    %{
      "version" => "v1.0",
      "callRendererFunction" => %{
        "functionCallId" => id,
        "surfaceId" => "functions",
        "callFunction" => function_call
      }
    }
  end
end

defmodule Gallery.Scenarios.Errors do
  @moduledoc """
  What the renderer does with messages it cannot apply. The session
  validates component batches with the relaxed configuration
  (`A2UICore.Validation.Config.relaxed/0`), which allows what streaming
  needs (a child that has not arrived yet) and rejects the rest. Each
  control makes the agent send one faulty message; the renderer rejects
  it whole, keeps what it had, and reports an `error` message to the
  agent, which says what it heard and, for an update to a surface that
  does not exist, recovers by creating the surface. Problems found while
  resolving (a function used where it may not run, a function failing)
  are diagnostics on the surface instead.
  """

  use Gallery.Scenario

  alias A2UICore.Validation.Config

  def id, do: "errors"
  def title, do: "Errors and recovery"

  def summary,
    do:
      "Faulty messages: how the renderer rejects them, what it reports to the agent, and how the agent recovers."

  def features,
    do: [
      "error messages",
      "VALIDATION_FAILED",
      "integrity: cycles",
      "unknown component",
      "unknown surface",
      "duplicate surface",
      "unknown catalog",
      "version mismatch",
      "reserved keys",
      "placeholders for missing children",
      "requiresUserActivation",
      "diagnostics"
    ]

  @basic_v09 "https://a2ui.org/specification/v0_9/catalogs/basic/catalog.json"

  def session_options, do: [validation: Config.relaxed()]

  def catalogs, do: [Gallery.Catalogs.basic("v1.0"), Gallery.Catalogs.basic("v0.9.1")]

  def messages do
    [
      create("main",
        data: %{"status" => "Nothing reported yet. Press a button above."},
        components: [
          %{"id" => "root", "component" => "Column", "children" => ["title", "intro", "status"]},
          text("title", "## Errors and recovery"),
          text(
            "intro",
            "Each button makes the agent send a faulty message. The renderer rejects it, keeps the surface as it was " <>
              "and reports the error to the agent; the Messages tab shows both sides.",
            %{"variant" => "caption"}
          ),
          text("status", path("/status"), %{"accessibility" => %{"live" => "polite"}})
        ]
      )
    ]
  end

  def controls,
    do: [
      {"ghost", "Update a surface that does not exist"},
      {"duplicate", "Create a surface twice"},
      {"invalid", "Send a Text without text"},
      {"unknown_type", "Send an unknown component"},
      {"cycle", "Send a cycle"},
      {"missing_child", "Refer to a child sent later"},
      {"catalog", "Use an unknown catalog"},
      {"version", "Mix catalog versions"},
      {"unsupported", "Send an unsupported version"},
      {"reserved", "Use a reserved @ key"},
      {"passive", "Bind openUrl to a text"},
      {"failing", "Make a function fail"}
    ]

  def control("ghost"), do: [{100, components("ghost", [text("root", "Hello from a ghost.")])}]
  def control("duplicate"), do: [{100, create("main")}]

  def control("invalid"),
    do: [
      {100,
       components("main", [%{"id" => "status", "component" => "Text", "variant" => "caption"}])}
    ]

  def control("unknown_type"),
    do: [
      {100,
       components("main", [%{"id" => "status", "component" => "Chart", "series" => [1, 2, 3]}])}
    ]

  def control("cycle") do
    [
      {100,
       components("main", [
         %{
           "id" => "root",
           "component" => "Column",
           "children" => ["title", "intro", "status", "loopA"]
         },
         %{"id" => "loopA", "component" => "Column", "children" => ["loopB"]},
         %{"id" => "loopB", "component" => "Column", "children" => ["loopA"]}
       ])}
    ]
  end

  # Allowed by the relaxed configuration: the child renders as a
  # placeholder until it arrives.
  def control("missing_child") do
    [
      {100,
       components("main", [
         %{
           "id" => "root",
           "component" => "Column",
           "children" => ["title", "intro", "status", "later"]
         }
       ])},
      {1_500,
       components("main", [text("later", "I arrived a moment later.", %{"variant" => "caption"})])}
    ]
  end

  def control("catalog"),
    do: [
      {100,
       create("elsewhere",
         catalog_id: "https://example.com/a2ui/catalogs/unknown/v1/catalog.json"
       )}
    ]

  # A v1.0 surface cannot take a component from a v0.9 catalog.
  def control("version") do
    [
      {100,
       components("main", [
         %{
           "id" => "status",
           "component" => "Text",
           "catalogId" => @basic_v09,
           "text" => "From the v0.9 catalog"
         }
       ])}
    ]
  end

  def control("unsupported"),
    do: [{100, %{"version" => "v99.0", "deleteSurface" => %{"surfaceId" => "main"}}}]

  def control("reserved"),
    do: [{100, components("main", [text("status", path("/status"), %{"@color" => "red"})])}]

  # openUrl requires a user gesture: bound to a property, it does not run
  # and the renderer reports an expression error.
  def control("passive") do
    [
      {100,
       [
         components("main", [
           %{
             "id" => "root",
             "component" => "Column",
             "children" => ["title", "intro", "status", "passive"]
           },
           text("passive", call("openUrl", %{"url" => "https://a2ui.org"}))
         ])
       ]}
    ]
  end

  # formatNumber gets the status text, which is not a number.
  def control("failing") do
    [
      {100,
       [
         components("main", [
           %{
             "id" => "root",
             "component" => "Column",
             "children" => ["title", "intro", "status", "failing"]
           },
           text("failing", call("formatNumber", %{"value" => path("/status")}))
         ])
       ]}
    ]
  end

  def control(_id), do: []

  # The agent hears of every error. An update to a surface that does not
  # exist is recoverable: create the surface and send the update again.
  def reply(%{"error" => %{"surfaceId" => "ghost"} = error}) do
    [
      {200, {:text, "The renderer has no surface ghost (#{error["code"]}). Creating it first."}},
      {400,
       [
         create("ghost"),
         components("ghost", [text("root", "Hello from a ghost, created on the second try.")])
       ]}
    ]
  end

  def reply(%{"error" => error}) do
    where = error["path"] && " at #{error["path"]}"

    [
      {200, {:text, "The renderer reported #{error["code"]}#{where}."}},
      {200,
       data(
         "main",
         "/status",
         "Last error reported: #{error["code"]}#{where}: #{error["message"]}"
       )}
    ]
  end

  def reply(_message), do: []
end

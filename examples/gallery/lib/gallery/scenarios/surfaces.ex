defmodule Gallery.Scenarios.Surfaces do
  @moduledoc """
  Several surfaces and their life cycle: an inbox created in one message
  with its components and data, a compose form the agent opens on
  request and closes when the message is sent, a notice opened and
  dismissed, components replaced, added and changed in type, and an
  `openUrl` action. The inbox sends its data model with every message,
  which is how the agent knows where to append the message just sent.
  """

  use Gallery.Scenario

  def id, do: "surfaces"
  def title, do: "Surfaces"

  def summary,
    do:
      "Creating, updating and deleting surfaces; several surfaces at once; component replacement; openUrl."

  def features,
    do: [
      "createSurface with components and dataModel",
      "several surfaces",
      "deleteSurface",
      "updateComponents: replace, add, change type",
      "userMessage",
      "sendDataModel",
      "openUrl"
    ]

  @messages [
    %{"from" => "Grace", "subject" => "Lunch on Friday?", "read" => false},
    %{"from" => "Alan", "subject" => "The machine works", "read" => true},
    %{"from" => "Ada", "subject" => "Notes on the engine", "read" => true}
  ]

  def messages do
    [
      create("inbox",
        send_data_model: true,
        data: %{"messages" => @messages, "count" => length(@messages)},
        components: inbox()
      )
    ]
  end

  defp inbox do
    [
      %{
        "id" => "root",
        "component" => "Column",
        "children" => ["title", "summary", "messages", "actions"]
      },
      text("title", "## Inbox"),
      text(
        "summary",
        call("pluralize", %{
          "value" => path("/count"),
          "one" => "One message.",
          "other" => call("formatString", %{"value" => "${/count} messages."})
        }),
        %{"variant" => "caption"}
      ),
      %{
        "id" => "messages",
        "component" => "List",
        "children" => %{"componentId" => "message", "path" => "/messages"}
      },
      message_row("message"),
      text("from", call("formatString", %{"value" => "**${from}**"})),
      text("subject", path("subject"), %{"weight" => 1}),
      %{"id" => "actions", "component" => "Row", "children" => ["compose", "help"]}
    ] ++
      button(
        "compose",
        "Write a message",
        %{"event" => %{"name" => "compose", "userMessage" => "I want to write a message."}},
        %{"variant" => "primary"}
      ) ++
      button(
        "help",
        "What is A2UI?",
        %{"functionCall" => call("openUrl", %{"url" => "https://a2ui.org"})},
        %{"variant" => "borderless"}
      )
  end

  defp message_row(id),
    do: %{
      "id" => id,
      "component" => "Row",
      "align" => "center",
      "children" => ["from", "subject"]
    }

  defp compose do
    [
      %{
        "id" => "root",
        "component" => "Column",
        "children" => ["title", "to", "subject", "body", "buttons"]
      },
      text("title", "## New message"),
      %{"id" => "to", "component" => "TextField", "label" => "To", "value" => path("/draft/to")},
      %{
        "id" => "subject",
        "component" => "TextField",
        "label" => "Subject",
        "value" => path("/draft/subject")
      },
      %{
        "id" => "body",
        "component" => "TextField",
        "label" => "Message",
        "variant" => "longText",
        "value" => path("/draft/body")
      },
      %{
        "id" => "buttons",
        "component" => "Row",
        "justify" => "end",
        "children" => ["discard", "send"]
      }
    ] ++
      button("discard", "Discard", event("discard")) ++
      button(
        "send",
        "Send",
        %{
          "event" => %{
            "name" => "send",
            "context" => %{"draft" => path("/draft")},
            "userMessage" =>
              call("formatString", %{"value" => "Send \"${/draft/subject}\" to ${/draft/to}."})
          }
        },
        %{
          "variant" => "primary",
          "checks" => [
            %{
              "condition" => call("required", %{"value" => path("/draft/subject")}),
              "message" => "Give it a subject."
            }
          ]
        }
      )
  end

  defp notice do
    [
      %{"id" => "root", "component" => "Card", "child" => "body"},
      %{
        "id" => "body",
        "component" => "Row",
        "align" => "center",
        "children" => ["icon", "text", "dismiss"]
      },
      %{"id" => "icon", "component" => "Icon", "name" => "notifications"},
      text("text", "The office closes early on Friday.", %{"weight" => 1})
    ] ++ button("dismiss", "Dismiss", event("dismiss"), %{"variant" => "borderless"})
  end

  def reply(%{"action" => %{"name" => "compose"}}, _data_models) do
    [
      {250,
       create("compose",
         data: %{"draft" => %{"to" => "Grace", "subject" => "", "body" => ""}},
         components: compose()
       )}
    ]
  end

  # The inbox's data model came with the action, so the agent knows how
  # many messages it holds and appends at the end.
  def reply(%{"action" => %{"name" => "send", "context" => %{"draft" => draft}}}, data_models) do
    count = data_models |> get_in(["inbox", "messages"]) |> List.wrap() |> length()
    sent = %{"from" => "Me → #{draft["to"]}", "subject" => draft["subject"], "read" => true}

    [
      {200, {:text, "Sent \"#{draft["subject"]}\"."}},
      {300,
       [
         delete("compose"),
         data("inbox", "/messages/#{count}", sent),
         data("inbox", "/count", count + 1)
       ]}
    ]
  end

  def reply(%{"action" => %{"name" => "discard"}}, _data_models), do: [{150, delete("compose")}]
  def reply(%{"action" => %{"name" => "dismiss"}}, _data_models), do: [{150, delete("notice")}]
  def reply(_message, _data_models), do: []

  def controls,
    do: [
      {"notice", "Open a notice"},
      {"retitle", "Replace the title"},
      {"footer", "Add a footer"},
      {"cards", "Change the rows into cards"}
    ]

  def control("notice"), do: [{100, create("notice", components: notice())}]

  # Same id, same type: the component is replaced.
  def control("retitle"),
    do: [{100, components("inbox", [text("title", "## Inbox (updated by the agent)")])}]

  # A new component, and its parent again with one more child.
  def control("footer") do
    [
      {100,
       components("inbox", [
         %{
           "id" => "root",
           "component" => "Column",
           "children" => ["title", "summary", "messages", "actions", "footer"]
         },
         text("footer", "Messages older than 30 days are archived.", %{"variant" => "caption"})
       ])}
    ]
  end

  # Same id, another type: the Row becomes a Card holding a new Row.
  def control("cards") do
    [
      {100,
       components("inbox", [
         %{"id" => "message", "component" => "Card", "child" => "messageRow"},
         message_row("messageRow")
       ])}
    ]
  end

  def control(_id), do: []
end

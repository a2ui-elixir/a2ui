defmodule Gallery.Scenarios.Forms do
  @moduledoc """
  A sign-up form: checks on every input (`required`, `length`, `regex`,
  `email`, `numeric`, combined with `and`, `or` and `not`), a button that
  stays disabled until they pass, and a surface that sends its data model
  with every message. The agent answers the submission by replacing the
  form with a summary, and brings the form back on request: the data
  model keeps what was typed.
  """

  use Gallery.Scenario

  def id, do: "forms"
  def title, do: "Forms and validation"

  def summary,
    do:
      "Checks on inputs, a button enabled only when they pass, sendDataModel, and a reply that swaps the form for a summary."

  def features,
    do: [
      "checks",
      "required / length / regex / email / numeric",
      "and / or / not",
      "Button checks",
      "ValidationResult",
      "sendDataModel",
      "event context",
      "updateComponents"
    ]

  @form %{
    "name" => "",
    "username" => "",
    "email" => "",
    "phone" => "",
    "age" => 17,
    "password" => "",
    "plan" => [],
    "terms" => false
  }

  def messages do
    [
      create("signup", send_data_model: true, data: %{"form" => @form}, components: form()),
      text_message()
    ]
  end

  defp text_message,
    do: data("signup", "/hint", "Fill in the form: each field says what it needs.")

  defp check(condition, message), do: %{"condition" => condition, "message" => message}
  defp required(path), do: call("required", %{"value" => path(path)})

  defp form do
    [
      %{
        "id" => "root",
        "component" => "Column",
        "children" => [
          "title",
          "hint",
          "accountLabel",
          "name",
          "username",
          "email",
          "phone",
          "age",
          "password",
          "planLabel",
          "plan",
          "terms",
          "actions"
        ]
      },
      text("title", "## Create an account"),
      text("hint", path("/hint"), %{"variant" => "caption"}),
      text("accountLabel", "##### Your account"),
      %{
        "id" => "name",
        "component" => "TextField",
        "label" => "Full name",
        "value" => path("/form/name"),
        "checks" => [
          check(required("/form/name"), "Tell us your name."),
          check(
            call("length", %{"value" => path("/form/name"), "min" => 2}),
            "At least two letters."
          )
        ]
      },
      %{
        "id" => "username",
        "component" => "TextField",
        "label" => "Username",
        "value" => path("/form/username"),
        "checks" => [
          check(
            call("regex", %{"value" => path("/form/username"), "pattern" => "^[a-z0-9_]{3,16}$"}),
            "3 to 16 lowercase letters, digits or _."
          ),
          check(
            call("not", %{
              "value" =>
                call("regex", %{"value" => path("/form/username"), "pattern" => "^(admin|root)$"})
            }),
            "That username is taken."
          )
        ]
      },
      %{
        "id" => "email",
        "component" => "TextField",
        "label" => "Email",
        "value" => path("/form/email"),
        "checks" => [
          check(
            call("or", %{
              "values" => [
                call("not", %{"value" => required("/form/email")}),
                call("email", %{"value" => path("/form/email")})
              ]
            }),
            "That is not an email address."
          )
        ]
      },
      %{
        "id" => "phone",
        "component" => "TextField",
        "label" => "Phone (or leave it empty and give an email)",
        "value" => path("/form/phone"),
        "checks" => [
          check(
            call("or", %{"values" => [required("/form/email"), required("/form/phone")]}),
            "Give an email address or a phone number."
          ),
          check(
            call("or", %{
              "values" => [
                call("not", %{"value" => required("/form/phone")}),
                call("regex", %{"value" => path("/form/phone"), "pattern" => "^\\+?[0-9 ]{6,}$"})
              ]
            }),
            "Digits and spaces only."
          )
        ]
      },
      %{
        "id" => "age",
        "component" => "TextField",
        "label" => "Age",
        "variant" => "number",
        "value" => path("/form/age"),
        "checks" => [
          check(
            call("numeric", %{"value" => path("/form/age"), "min" => 18, "max" => 120}),
            "You must be 18 or older."
          )
        ]
      },
      %{
        "id" => "password",
        "component" => "TextField",
        "label" => "Password",
        "variant" => "obscured",
        "value" => path("/form/password"),
        "checks" => [
          check(
            call("length", %{"value" => path("/form/password"), "min" => 8}),
            "At least 8 characters."
          ),
          check(
            call("regex", %{"value" => path("/form/password"), "pattern" => "[0-9]"}),
            "Include a digit."
          )
        ]
      },
      text("planLabel", "##### Your plan"),
      %{
        "id" => "plan",
        "component" => "ChoicePicker",
        "label" => "Plan",
        "displayStyle" => "chips",
        "options" => [
          %{"label" => "Free", "value" => "free"},
          %{"label" => "Pro", "value" => "pro"},
          %{"label" => "Team", "value" => "team"}
        ],
        "value" => path("/form/plan"),
        "checks" => [check(required("/form/plan"), "Pick a plan.")]
      },
      %{
        "id" => "terms",
        "component" => "CheckBox",
        "label" => "I accept the terms",
        "value" => path("/form/terms"),
        "checks" => [check(path("/form/terms"), "Accept the terms to continue.")]
      },
      %{"id" => "actions", "component" => "Row", "justify" => "end", "children" => ["submit"]}
    ] ++
      button("submit", "Create account", event("signup", %{"form" => path("/form")}), %{
        "variant" => "primary",
        "checks" => [
          check(
            call("and", %{
              "values" => [
                required("/form/name"),
                call("regex", %{
                  "value" => path("/form/username"),
                  "pattern" => "^[a-z0-9_]{3,16}$"
                }),
                call("or", %{"values" => [required("/form/email"), required("/form/phone")]}),
                call("numeric", %{"value" => path("/form/age"), "min" => 18}),
                call("length", %{"value" => path("/form/password"), "min" => 8}),
                required("/form/plan"),
                path("/form/terms")
              ]
            }),
            "Complete the form first."
          )
        ]
      })
  end

  defp welcome do
    [
      %{
        "id" => "root",
        "component" => "Column",
        "children" => ["done", "welcome", "contact", "again"],
        "align" => "center"
      },
      %{"id" => "done", "component" => "Icon", "name" => "check"},
      text("welcome", call("formatString", %{"value" => "## Welcome, ${/form/name}!"})),
      text(
        "contact",
        call("formatString", %{
          "value" =>
            "Your ${/form/plan/0} account is ready. We will write to ${/form/email}${/form/phone}."
        }),
        %{"variant" => "caption"}
      ),
      %{"id" => "again", "component" => "Row", "justify" => "center", "children" => ["edit"]}
    ] ++ button("edit", "Edit my details", event("edit"))
  end

  # The submission arrives with the form in its context; the surface's
  # data model also travels with every message (sendDataModel).
  def reply(%{"action" => %{"name" => "signup", "context" => %{"form" => form}}}) do
    [
      {300, {:text, "Thanks, #{form["name"]}. Your account is ready."}},
      {300, [components("signup", welcome())]}
    ]
  end

  def reply(%{"action" => %{"name" => "edit"}}),
    do: [
      {200,
       [
         components("signup", form()),
         data("signup", "/hint", "Your details are as you left them.")
       ]}
    ]

  def reply(_message), do: []

  def controls, do: [{"fill", "Fill in a valid form"}]

  # The agent may also write the data model: here it fills the form in.
  def control("fill") do
    [
      {100,
       data("signup", "/form", %{
         "name" => "Ada Lovelace",
         "username" => "ada_l",
         "email" => "ada@example.com",
         "phone" => "",
         "age" => 36,
         "password" => "engine1843",
         "plan" => ["pro"],
         "terms" => true
       })}
    ]
  end
end

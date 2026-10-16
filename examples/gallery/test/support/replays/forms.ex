defmodule Gallery.Replays.Forms do
  @moduledoc """
  The gallery's forms scenario: checks the renderer runs on every input,
  a button enabled only when they pass, a submission that carries the
  surface's data model, and the agent's answers.
  """

  alias A2UIPhoenix.Session
  alias Gallery.Replays.Recorder
  alias Gallery.Scenarios.Forms, as: Scenario

  @surface "signup"

  @doc "The replay."
  def replay do
    %{
      "id" => "forms",
      "title" => "Forms and validation",
      "source" => "examples/gallery",
      "summary" =>
        "Checks run in the renderer as you type, a button enabled when they pass, and a submission with sendDataModel.",
      "steps" => Recorder.steps(record())
    }
  end

  # What the user types, and what the renderer's checks make of it.
  @typing [
    {"Full name", "Ada Lovelace", "Type a name", "The name passes required and length."},
    {"Username", "admin", "Try the username admin",
     "\"admin\" matches the pattern, but a not(regex) check rejects it: that username is taken."},
    {"Username", "ada_l", "Try ada_l", "A free username."},
    {"Email", "ada@", "Start an email address", "email() fails: this is not an address yet."},
    {"Email", "ada@example.com", "Finish it",
     "A valid address. It also satisfies the phone field, which asks for an email or a phone number."},
    {"Age", 36, "Change the age to 36", "numeric() with a minimum of 18 passes."},
    {"Password", "engine", "Type a short password",
     "Two checks fail: at least 8 characters, and a digit."},
    {"Password", "engine1843", "Make it longer, with digits", "Both pass."}
  ]

  defp record do
    session = Session.new(Scenario.catalogs(), Recorder.session_options(Scenario))
    messages = Scenario.messages()
    {session, out} = Recorder.apply(session, messages)

    start = %{
      caption:
        "The agent sends a sign-up form whose inputs carry checks. The renderer runs them and keeps the button disabled until they all pass.",
      entries: entries(messages, out),
      surfaces: Recorder.surfaces(session)
    }

    {typed, session} =
      Enum.map_reduce(@typing, session, fn {label, value, text, caption}, session ->
        field = Recorder.field(session, @surface, label)
        next = Recorder.type_move(input(field), value, text)
        {session, []} = Recorder.write(session, @surface, field, value)
        {{next, %{caption: caption, surfaces: Recorder.surfaces(session)}}, session}
      end)

    plan = Recorder.field(session, @surface, "Plan")

    pick =
      Recorder.click_move(
        ~s(##{Recorder.dom_id(@surface, plan)} [phx-value-option="pro"]),
        "Pro",
        "Pick the Pro plan"
      )

    {session, []} = Recorder.write(session, @surface, plan, ["pro"])

    picked = %{
      caption: "Pro is picked, which passes the plan's required check.",
      surfaces: Recorder.surfaces(session)
    }

    terms = Recorder.field(session, @surface, "I accept the terms")
    accept = Recorder.click_move(input(terms), "I accept the terms", "Accept the terms")
    {session, []} = Recorder.write(session, @surface, terms, true)

    accepted = %{
      caption: "The last check passes, and the button turns on.",
      surfaces: Recorder.surfaces(session)
    }

    submit = Recorder.button(session, @surface, "Create account")
    create = Recorder.click_move("#" <> Recorder.dom_id(@surface, submit), "Create account")
    {session, [signup]} = Recorder.click(session, @surface, submit)
    {session, said, sent} = answer(session, signup)

    welcomed = %{
      caption:
        "The action carries the form, and the surface's data model travels with it (sendDataModel). The agent swaps the form for a summary written with formatString.",
      said: said,
      entries: sent,
      surfaces: Recorder.surfaces(session)
    }

    edit = Recorder.button(session, @surface, "Edit my details")
    back = Recorder.click_move("#" <> Recorder.dom_id(@surface, edit), "Edit my details")
    {session, [again]} = Recorder.click(session, @surface, edit)
    {session, said, sent} = answer(session, again)

    edited = %{
      caption: "The agent brings the form back, and the data model kept what was typed.",
      said: said,
      entries: sent,
      surfaces: Recorder.surfaces(session)
    }

    Recorder.chain(
      start,
      typed ++ [{pick, picked}, {accept, accepted}, {create, welcomed}, {back, edited}]
    )
  end

  defp input(field), do: "#" <> Recorder.dom_id(@surface, field, "input")

  # The renderer sends the action with the data models of the surfaces
  # created with sendDataModel, and the agent answers.
  defp answer(session, action) do
    {:ok, %{"surfaces" => data_models}} = Session.client_data_model(session)

    note =
      action["action"]["name"] <>
        " · with the data model of " <> Enum.join(Map.keys(data_models), ", ")

    sent = [Recorder.entry(:out, action, note)]

    Enum.reduce(Scenario.reply(action, data_models), {session, nil, sent}, fn
      {_delay, {:text, text}}, {session, _said, sent} ->
        {session, text, sent}

      {_delay, messages}, {session, said, sent} ->
        messages = List.wrap(messages)
        {session, out} = Recorder.apply(session, messages)
        {session, said, sent ++ entries(messages, out)}
    end)
  end

  defp entries(messages, out),
    do: Enum.map(messages, &Recorder.entry(:in, &1)) ++ Enum.map(out, &Recorder.entry(:out, &1))
end

defmodule Gallery.Replays do
  @moduledoc """
  Recorded runs of the examples for the landing page (`site/`), which is
  static and cannot run them. Each replay is the real agent and a real
  `A2UIPhoenix.Session`, step by step: the HTML the renderer draws for
  each surface and the messages that cross. `mix gallery.replays` writes
  them into the site.
  """

  alias Gallery.Replays.{Booking, Forms, Streaming}

  @doc "Every replay, in the order the page shows them."
  def all, do: [Booking.replay(), Streaming.replay(), Forms.replay()]

  @doc "The replays (a fresh recording unless given) as the JSON document the site reads."
  def json(replays \\ all()), do: Jason.encode!(%{"replays" => replays}, pretty: true) <> "\n"

  @doc "The renderer's stylesheet, which the site serves next to the replays."
  def stylesheet,
    do: Path.join(Application.app_dir(:a2ui_phoenix, "priv/static"), "a2ui_phoenix.css")

  @doc "Where the site keeps `json/0` and a copy of `stylesheet/0`, under its directory `site`."
  def targets(site),
    do: %{
      json: Path.join(site, "priv/replays.json"),
      stylesheet: Path.join(site, "priv/static/assets/a2ui_phoenix.css")
    }
end

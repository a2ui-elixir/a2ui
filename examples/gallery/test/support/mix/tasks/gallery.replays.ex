defmodule Mix.Tasks.Gallery.Replays do
  @shortdoc "Records the replays the landing page plays"
  @moduledoc """
  Records the replays of the landing page (`Gallery.Replays`): the
  restaurant agent's booking conversation, the streaming scenario and
  the forms scenario, each run against a real renderer session.

      mix gallery.replays [--site DIR]

  Writes `priv/replays.json` and a copy of the renderer's stylesheet
  (`priv/static/assets/a2ui_phoenix.css`) into the site, `../../site`
  unless `--site` says otherwise. It runs in the test environment, where
  the restaurant agent is a dependency of the gallery.
  """

  use Mix.Task

  @requirements ["app.start"]

  @impl Mix.Task
  def run(args) do
    {options, _rest} = OptionParser.parse!(args, strict: [site: :string])
    site = Path.expand(options[:site] || "../../site")
    targets = Gallery.Replays.targets(site)

    File.mkdir_p!(Path.dirname(targets.json))
    File.write!(targets.json, Gallery.Replays.json())
    File.mkdir_p!(Path.dirname(targets.stylesheet))
    File.cp!(Gallery.Replays.stylesheet(), targets.stylesheet)

    for path <- [targets.json, targets.stylesheet],
        do: Mix.shell().info("* wrote #{Path.relative_to_cwd(path)}")
  end
end

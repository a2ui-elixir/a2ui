defmodule Mix.Tasks.Gallery.Replays do
  @shortdoc "Records the replays the landing page plays"
  @moduledoc """
  Records the replays of the landing page (`Gallery.Replays`): the
  restaurant agent's booking conversation, the streaming scenario and
  the forms scenario, each run against a real renderer session.

      mix gallery.replays [--site DIR]

  Writes `priv/replays.json` and copies of the stylesheets the replays are
  drawn with (`priv/static/assets/a2ui_phoenix.css` and `catalog.css`)
  into the site, `../../site` unless `--site` says otherwise. It runs in the test environment, where
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

    for {source, copy} <- targets.stylesheets do
      File.mkdir_p!(Path.dirname(copy))
      File.cp!(source, copy)
    end

    for path <- [targets.json | Map.values(targets.stylesheets)],
        do: Mix.shell().info("* wrote #{Path.relative_to_cwd(path)}")
  end
end

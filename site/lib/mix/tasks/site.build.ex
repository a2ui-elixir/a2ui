defmodule Mix.Tasks.Site.Build do
  @shortdoc "Writes the landing page as static files"
  @moduledoc """
  Writes the landing page and its assets as static files.

      mix site.build              # into dist/
      mix site.build --out DIR

  Serve the directory with any static file server, under any path.
  """
  use Mix.Task

  @impl Mix.Task
  def run(args) do
    {options, _rest} = OptionParser.parse!(args, strict: [out: :string])
    dir = Path.expand(options[:out] || "dist")

    Mix.Task.run("compile")
    {:ok, _apps} = Application.ensure_all_started(:phoenix_html)

    written = Site.Static.build(dir)
    Mix.shell().info("Wrote #{length(written)} files to #{Path.relative_to_cwd(dir)}:")
    Enum.each(written, &Mix.shell().info("  " <> &1))
  end
end

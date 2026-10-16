defmodule Site.StaticTest do
  use ExUnit.Case, async: true

  import Phoenix.ConnTest

  @endpoint SiteWeb.Endpoint

  test "the exported page is the page the server sends" do
    served = build_conn() |> get("/") |> html_response(200)
    assert Site.Static.page() == served
    assert String.starts_with?(served, "<!DOCTYPE html>")
  end

  @tag :tmp_dir
  test "build/1 writes the page and every static file", %{tmp_dir: dir} do
    written = Site.Static.build(dir)

    for path <-
          ~w(index.html assets/site.css assets/site.js assets/fonts/Geist-Variable.woff2 assets/fonts/GeistMono-Variable.woff2 assets/fonts/LICENSE-OFL.txt favicon.svg robots.txt) do
      assert path in written
      assert File.regular?(Path.join(dir, path))
    end

    assert File.read!(Path.join(dir, "index.html")) == Site.Static.page()
  end

  @tag :tmp_dir
  test "mix site.build writes into --out", %{tmp_dir: dir} do
    Mix.shell(Mix.Shell.Process)
    on_exit(fn -> Mix.shell(Mix.Shell.IO) end)

    Mix.Tasks.Site.Build.run(["--out", dir])

    assert_received {:mix_shell, :info, ["Wrote " <> summary]}
    assert summary =~ "files to"
    assert File.regular?(Path.join(dir, "index.html"))
  end
end

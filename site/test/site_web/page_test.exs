defmodule SiteWeb.PageTest do
  use ExUnit.Case, async: true

  import Phoenix.ConnTest

  alias Site.Content

  @endpoint SiteWeb.Endpoint

  setup_all do
    html = build_conn() |> get("/") |> html_response(200)
    %{html: html, doc: LazyHTML.from_document(html)}
  end

  defp text(doc, selector), do: doc |> LazyHTML.query(selector) |> LazyHTML.text() |> squish()

  defp squish(text), do: text |> String.split() |> Enum.join(" ")

  defp plain(text), do: text |> String.replace("`", "") |> squish()

  defp attributes(doc, selector, name),
    do: doc |> LazyHTML.query(selector) |> LazyHTML.attribute(name)

  test "the page has its title and its sections", %{doc: doc} do
    assert text(doc, "title") =~ "A2UI for Elixir"
    assert text(doc, "h1") == "Agents describe it. Phoenix renders it."

    for {_label, id} <- SiteWeb.PageHTML.nav_links() do
      assert LazyHTML.query(doc, "section#" <> id) |> Enum.count() == 1
    end
  end

  test "every feature is on the page", %{doc: doc} do
    features = text(doc, "#features")

    for group <- Content.feature_groups(), line <- [group.title | group.items] do
      assert features =~ plain(line)
    end
  end

  test "the figures, the lifecycle and the packages are on the page", %{doc: doc} do
    page = text(doc, "main")

    for stat <- Content.stats(),
        line <- [stat.key, stat.value, stat.label],
        do: assert(page =~ line)

    for step <- Content.lifecycle(), line <- [step.title, step.text, step.module] do
      assert page =~ line
    end

    for package <- Content.packages(), line <- [package.name, package.summary | package.points] do
      assert page =~ line
    end
  end

  test "the catalog lists every component and function", %{doc: doc} do
    catalog = text(doc, "#catalog")

    for {_kind, names} <- Content.components() ++ Content.functions(), name <- names do
      assert catalog =~ name
    end

    for catalog_entry <- Content.mcp_catalogs(),
        name <- catalog_entry.components ++ catalog_entry.functions do
      assert catalog =~ name
    end

    assert LazyHTML.query(doc, "#catalog .component svg.wireframe") |> Enum.count() == 18
  end

  test "the transports, the examples and the scenarios are on the page", %{doc: doc} do
    transports = text(doc, "#transports")

    for transport <- Content.transports() do
      assert transports =~ plain(transport.detail)
      assert transports =~ transport.where
    end

    examples = text(doc, "#examples")

    for example <- Content.examples(), line <- [example.name, example.path, example.summary] do
      assert examples =~ line
    end

    for {name, shows} <- Content.scenarios(), do: assert(examples =~ name <> " " <> plain(shows))
  end

  test "the replay player shows the first step of the first replay", %{doc: doc} do
    replays = Site.Replays.all()
    [first | _] = replays
    step = hd(first["steps"])

    tabs =
      doc |> LazyHTML.query(".replay-tabs [role=tab]") |> Enum.map(&squish(LazyHTML.text(&1)))

    assert tabs == Enum.map(replays, & &1["title"])
    assert text(doc, "[data-replay-source]") == first["source"]
    assert text(doc, "[data-replay-caption]") == step["caption"]
    assert text(doc, "[data-replay-next-label]") == step["next"]["text"]

    chat = text(doc, "[data-replay-chat]")
    assert chat =~ step["user"]
    assert chat =~ step["said"]

    for {id, html} <- step["surfaces"] do
      figure = LazyHTML.query(doc, ~s([data-replay-chat] [data-surface="#{id}"] .replay-stage))
      surface = LazyHTML.from_fragment(html)
      assert text(figure, ".a2ui-surface") == squish(LazyHTML.text(surface))
    end

    kinds = doc |> LazyHTML.query("[data-replay-log] .log-kind") |> Enum.map(&LazyHTML.text/1)
    assert kinds == Enum.map(step["entries"], & &1["kind"])

    for entry <- step["entries"] do
      assert text(doc, "[data-replay-log]") =~
               squish(Jason.encode!(entry["message"], pretty: true))
    end
  end

  test "the page holds every replay, in a script nothing can end early", %{doc: doc} do
    [script] = doc |> LazyHTML.query("script#replay-data") |> Enum.to_list()
    json = LazyHTML.text(script)

    refute json =~ "<"

    assert Jason.decode!(json) ==
             Application.app_dir(:site, "priv/replays.json") |> File.read!() |> Jason.decode!()
  end

  test "the conformance report adds up", %{doc: doc} do
    report = text(doc, "#conformance")

    for suite <- Content.suites() do
      assert report =~ "#{suite.name} #{suite.run}/#{suite.total}"
      if suite.skipped, do: assert(report =~ "skipped: " <> suite.skipped)
    end

    assert report =~ "946/946 upstream cases that apply, all passing"
    assert report =~ "The suites hold 1144 cases; the other 198 do not apply"

    for reason <- Content.skip_reasons() do
      assert report =~ "#{reason.count} #{reason.title} #{reason.detail}"
    end
  end

  test "the code samples and the hero's message are shown whole", %{doc: doc} do
    for sample <- Content.samples() do
      code = doc |> LazyHTML.query("#panel-#{sample.id} pre code") |> LazyHTML.text()
      assert code == String.trim_trailing(sample.code)
    end

    hero =
      doc
      |> LazyHTML.query(".demo-code .line")
      |> Enum.map(fn line -> line |> LazyHTML.text() |> String.replace(~r/^\d+/, "") end)
      |> Enum.join("\n")

    assert hero == String.trim_trailing(Content.hero_message())
    assert {:ok, %{"createSurface" => %{"surfaceId" => "booking"}}} = Jason.decode(hero)
  end

  test "every link within the page has a target, and ids are unique", %{doc: doc} do
    ids = attributes(doc, "[id]", "id")
    assert ids == Enum.uniq(ids)

    for "#" <> id <- attributes(doc, "a[href^='#']", "href") do
      assert id in ids, "no element with id #{id}"
    end

    for href <- attributes(doc, "a[href^='http']", "href") do
      assert href =~ ~r{^https://}
    end
  end

  test "every asset the page and its stylesheet use exists" do
    static = Application.app_dir(:site, "priv/static")
    html = build_conn() |> get("/") |> html_response(200)
    doc = LazyHTML.from_document(html)

    links = attributes(doc, "link[href]", "href") ++ attributes(doc, "script[src]", "src")
    css = File.read!(Path.join(static, "assets/site.css"))
    fonts = for [_, url] <- Regex.scan(~r/url\("(fonts\/[^"]+)"\)/, css), do: "assets/" <> url

    assert "assets/site.css" in links
    assert "assets/a2ui_phoenix.css" in links
    assert "assets/catalog.css" in links
    assert length(fonts) == 3

    for path <- links ++ fonts do
      refute String.starts_with?(path, "/"),
             "#{path} is absolute; the static export needs relative paths"

      assert File.regular?(Path.join(static, path)), "#{path} is missing"
    end
  end

  test "the server sends the assets" do
    for {path, type} <- [
          {"/assets/site.css", "text/css"},
          {"/assets/site.js", "text/javascript"},
          {"/assets/fonts/Geist-Variable.woff2", "font/woff2"},
          {"/assets/a2ui_phoenix.css", "text/css"},
          {"/assets/catalog.css", "text/css"},
          {"/assets/fonts/MaterialSymbolsOutlined-subset.woff2", "font/woff2"},
          {"/favicon.svg", "image/svg+xml"}
        ] do
      conn = get(build_conn(), path)
      assert conn.status == 200
      assert [content_type] = Plug.Conn.get_resp_header(conn, "content-type")
      assert content_type =~ type
    end
  end
end

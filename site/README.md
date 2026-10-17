# Landing page

The project's landing page, as a small Phoenix application. It has no
dependency on the packages it describes: what it says is data in
`Site.Content`, and the tests check that data against this repository (the
vendored catalogs and schemas, the conformance table in `../README.md`,
`../SPEC_PIN`, the modules, guides and examples it names).

```bash
mix deps.get
mix phx.server        # http://localhost:4040; PORT overrides
mix test
mix site.build        # static files in dist/ (--out DIR to choose)
```

`mix site.build` writes `index.html` with the stylesheet, the script, the fonts
and the icon. Every link is relative, so the directory can be served by any
static host, under any path, or opened from disk.

CI publishes it on GitHub Pages, at <https://a2ui-elixir.github.io/a2ui/>: the
`site` job builds it, and the `pages` job deploys it from `main` once the
packages, the examples and the page pass. The address is `Site.Content.site_url/0`,
which the page names as its canonical URL and in its social preview metadata.
`priv/static/social.png` is that preview, 1200×630; a test checks its size.
The video section shows `priv/static/video.webp`, a frame of the video, and a
click on it swaps in YouTube's player (`Site.Content.video_embed_url/0`, the
no-cookie host); without the script it links to the video.

| Path | |
|---|---|
| `lib/site/content.ex` | Everything the page says: packages, features, catalog, transports, figures, examples, code samples. |
| `priv/replays.json`, `lib/site/replays.ex` | The recorded runs of the examples that the Examples section plays. `mix gallery.replays` in `examples/gallery` writes the file; the gallery's tests fail when it is not a fresh recording. |
| `lib/site_web/controllers/page_html/home.html.heex` | The page. |
| `lib/site_web/components.ex` | Icons, component wireframes, section headings, code panels. |
| `lib/site_web/code.ex` | The syntax highlighter for the code samples. |
| `lib/site/static.ex`, `lib/mix/tasks/site.build.ex` | The static export. |
| `priv/static/assets/` | The stylesheet (light and dark themes), the script, the Geist fonts (SIL Open Font License, `fonts/LICENSE-OFL.txt`), the stylesheets the replays are drawn with, the renderer's `a2ui_phoenix.css` and the gallery's `catalog.css` (copied by `mix gallery.replays`), and a subset of Material Symbols with the icons the replays show (Apache License 2.0, `fonts/LICENSE-Apache-2.0.txt`). |

The script only enhances the page: the theme switch, the code tabs, the copy
buttons, the replay of the opening animation and the data model it binds, and
the player of the recorded runs. Without it, every section and every code
sample is still there, and the player shows its first step.

The replays are themed like the rest of the page: the `.replay-stage` rule in
`site.css` sets the renderer's `--a2ui-*` tokens (colors, fonts) from the
page's own, and styles no component.

A replay that shows an icon the subset lacks fails the tests. The subset comes
from the Google Fonts CSS API with the icons' names, for example
`https://fonts.googleapis.com/css2?family=Material+Symbols+Outlined&icon_names=check,event,mail,person`
(the names in alphabetical order);
the stylesheet it returns links the font file. Add the new name to the list in
`test/site/content_test.exs`.

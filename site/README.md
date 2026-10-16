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

| Path | |
|---|---|
| `lib/site/content.ex` | Everything the page says: packages, features, catalog, transports, figures, examples, code samples. |
| `lib/site_web/controllers/page_html/home.html.heex` | The page. |
| `lib/site_web/components.ex` | Icons, component wireframes, section headings, code panels. |
| `lib/site_web/code.ex` | The syntax highlighter for the code samples. |
| `lib/site/static.ex`, `lib/mix/tasks/site.build.ex` | The static export. |
| `priv/static/assets/` | The stylesheet (light and dark themes), the script and the Geist fonts (SIL Open Font License, `fonts/LICENSE-OFL.txt`). |

The script only enhances the page: the theme switch, the code tabs, the copy
buttons, the replay of the opening animation and the data model it binds.
Without it, every section and every code sample is still there.

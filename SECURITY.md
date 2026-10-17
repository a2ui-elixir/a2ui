# Security

## Reporting a vulnerability

Please report security issues privately, through GitHub's
[private vulnerability reporting](https://github.com/a2ui-elixir/a2ui/security/advisories/new)
(the repository's Security tab, "Report a vulnerability"), not in a public
issue. Include the package and version, what an attacker can do, and the
steps or the input that show it.

## Supported versions

Fixes go into the latest release of `a2ui_core`, `a2ui_phoenix` and
`a2ui_agent`.

## What the packages defend against

A2UI surfaces come from an agent, which a renderer should treat as untrusted
input. The packages:

- with a validation configuration (`A2UICore.Validation.Config.relaxed/0`
  or `strict/0`, given to the processor or the session), check every
  component against its catalog's schema before it is applied; without
  one, component updates are applied unchecked, so give one when you do
  not control the agent;
- render text through HEEx, which escapes it, and render no HTML an agent
  sends, except inside the MCP catalog's `McpApp`, which runs it in a
  sandboxed iframe without same-origin access, under a Content Security
  Policy built from what its resource declares. A `:markdown` function you
  give `A2UIPhoenix.Surface` returns trusted HTML, so it must escape the
  HTML in the text it converts, as the gallery's `GalleryWeb.Markdown`
  does;
- write user input only to data paths a component binds, and invoke only
  the actions a component declares;
- open only `http`, `https`, `mailto` and `tel` URLs for `openUrl`, in a new
  window without an opener;
- stop a regular-expression search after a million backtracking steps, so
  a pattern an agent or catalog supplies cannot keep the server busy, and
  cap data-model indices, component-tree depth and function-call depth.

The details, per package, are in each package's guide on HexDocs.

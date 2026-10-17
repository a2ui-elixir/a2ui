# Changelog

## 0.1.1 (2026-10-17)

- Requires `a2ui_core` 0.1.1, which compiles on Elixir 1.17.

## 0.1.0 (2026-10-17)

First release.

- Catalog registration, transformers (component and function pruning) and
  negotiation with a renderer's capabilities, inline catalogs included.
- The direct JSON inference format: a prompt snippet with the negotiated
  catalogs' documents, the protocol schemas they use and few-shot examples,
  written as the reference SDKs write it, and a parser for complete and
  streamed responses that checks messages the way a renderer would.
- The Express inference format (`A2UIAgent.Express`): a prompt with the
  notation's rules and the signatures of the negotiated catalogs' components
  and functions, a compiler from Express blocks to validated messages and a
  decompiler back, written as the reference SDKs write them.
- Skills (`A2UIAgent.Skill`, `A2UIAgent.SkillGenerator`): a format's prompt
  packaged as one skill or as a core skill and one skill per catalog.
- A component builder (`A2UIAgent.Builder`, with a function per basic
  component in `A2UIAgent.Builder.Basic`): trees flattened into component
  lists with the reference's id scheme, completed with the catalog's
  defaults and checked against it, and packaged as messages.
- Macros (`A2UIAgent.Macro`, `A2UIAgent.MacroExpander`): components the
  model writes that expand into catalog components, an inference catalog
  that adds them to the base catalog, and their catalog schemas.
- `A2UIAgent.PayloadValidator`, `A2UIAgent.BlockLexer` and
  `A2UIAgent.PayloadFixer` (the reference's `parse_and_fix`).
- A2A: A2UI parts, extension negotiation, the `message/send` and
  `message/stream` methods (`A2UIAgent.A2A.Server`), and a plug that serves
  them over HTTP (`A2UIAgent.A2A.Plug`). A format that is not read chunk by
  chunk, such as Express, is answered once the output is complete.
- MCP and AG-UI: the values an MCP server returns and reads for A2UI
  (`A2UIAgent.MCP`), and AG-UI activity snapshots, events and user actions
  (`A2UIAgent.AGUI`).
- `A2UIAgent.Builder.call/3` takes `:catalog_id`, for a call into another
  catalog (v1.0).
- `A2UIAgent.DirectJson.Parser.decompile/1` writes each message's keys in the
  protocol's order, so that decompiled text streams component by component.
- Express, as in the Python SDK: a single data assignment to a nested path
  compiles to an update of that path; several assignments, or one to a
  top-level key, compile to one root update that merges them.
  `A2UIAgent.Express.Parser.decompile/3` takes `:surface_catalogs`, for
  updates to surfaces created earlier.

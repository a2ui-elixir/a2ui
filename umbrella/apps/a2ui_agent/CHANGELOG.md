# Changelog

## 0.1.0 (unreleased)

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
- `A2UIAgent.PayloadValidator` and `A2UIAgent.BlockLexer`.
- A2A: A2UI parts, extension negotiation, the `message/send` and
  `message/stream` methods (`A2UIAgent.A2A.Server`), and a plug that serves
  them over HTTP (`A2UIAgent.A2A.Plug`). A format that is not read chunk by
  chunk, such as Express, is answered once the output is complete.

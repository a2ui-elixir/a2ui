# Changelog

## 0.1.0 (unreleased)

First release.

- Catalog registration, transformers (component and function pruning) and
  negotiation with a renderer's capabilities, inline catalogs included.
- The direct JSON inference format: a prompt snippet with the negotiated
  catalogs' documents, the protocol schemas they use and few-shot examples,
  written as the reference SDKs write it, and a parser for complete and
  streamed responses that checks messages the way a renderer would.
- `A2UIAgent.PayloadValidator`.
- A2A: A2UI parts, extension negotiation, the `message/send` and
  `message/stream` methods (`A2UIAgent.A2A.Server`), and a plug that serves
  them over HTTP (`A2UIAgent.A2A.Plug`).

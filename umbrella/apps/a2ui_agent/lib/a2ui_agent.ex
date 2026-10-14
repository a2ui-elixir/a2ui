defmodule A2UIAgent do
  @moduledoc """
  Agent-side SDK for the A2UI protocol, built on `A2UICore`.

  An agent registers the catalogs it can write for, negotiates them with
  each renderer, tells the model how to write A2UI and reads the model's
  output back as validated messages.

    * `A2UIAgent.CatalogProvider`, `A2UIAgent.CatalogConfig` and
      `A2UIAgent.CatalogTransformer` — load the catalogs an agent
      registers and prune them to what it uses.
    * `A2UIAgent.CatalogResolver` — picks the active catalogs from a
      renderer's capabilities.
    * `A2UIAgent.Generator` and `A2UIAgent.RequestProcessor` — per
      request: the negotiated catalogs, the prompt snippet and parsers.
    * `A2UIAgent.DirectJson` — the direct JSON inference format: its
      prompt (`A2UIAgent.DirectJson.Prompt`) and its parser for complete
      and streamed responses (`A2UIAgent.DirectJson.Parser`).
    * `A2UIAgent.PayloadValidator` — checks a payload the way a renderer
      holding the same catalogs would.
    * `A2UIAgent.A2A`, `A2UIAgent.A2A.Server` and `A2UIAgent.A2A.Plug` —
      the A2A extension: A2UI parts and extension negotiation, the
      `message/send` and `message/stream` methods, and a plug that serves
      them over HTTP.

  Everything is plain data: there are no processes, and a streaming
  parser is a value that each chunk updates.
  """
end

defmodule A2UICore.ExamplesCorpusTest do
  @moduledoc false
  # Decodes every upstream basic-catalog example bundle and both JSONL
  # contact-form samples through the FULL pipeline — payload sniffing,
  # preflight, per-version envelope validation with the real catalog,
  # and operation extraction. This is the end-to-end wire-fidelity
  # gate for phases 2+.
  #
  # Skipped silently when the upstream checkout is absent.

  use ExUnit.Case, async: true

  alias A2UICore.Message
  alias A2UICore.Schema.Source

  @reference_root "../../../../reference/a2ui"

  @bundles [
    {"v1.0", "catalogs/basic/v1/examples/*.json"},
    {"v0.9.1", "specification/v0_9_1/catalogs/basic/examples/*.json"}
  ]

  @jsonl [
    {"v1.0", "specification/v1_0/test/cases/contact_form_example.jsonl"},
    {"v0.9.1", "specification/v0_9_1/test/cases/contact_form_example.jsonl"}
  ]

  for {version, glob} <- @bundles,
      root = Path.expand(@reference_root, __DIR__),
      file <- (File.dir?(root) && Path.wildcard(Path.join(root, glob)) || []) do
    @external_resource file

    @tag :examples_corpus
    test "decodes bundle #{Path.basename(file)} (#{version})" do
      bundle = unquote(file) |> File.read!() |> Jason.decode!()
      catalog = Source.catalog(unquote(version), :basic)

      assert {:ok, ops} = Message.decode(bundle["messages"], catalog: catalog)
      assert ops != []
    end
  end

  for {version, rel} <- @jsonl,
      root = Path.expand(@reference_root, __DIR__),
      file = Path.join(root, rel),
      File.exists?(file) do
    @external_resource file

    @tag :examples_corpus
    test "decodes JSONL #{Path.basename(rel)} (#{version})" do
      lines = unquote(file) |> File.read!() |> String.split("\n", trim: true)
      catalog = Source.catalog(unquote(version), :basic)

      for line <- lines do
        message = Jason.decode!(line)
        assert {:ok, _ops} = Message.decode(message, catalog: catalog)
      end
    end
  end
end
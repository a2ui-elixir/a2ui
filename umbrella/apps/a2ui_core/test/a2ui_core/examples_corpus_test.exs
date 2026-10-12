defmodule A2UICore.ExamplesCorpusTest do
  @moduledoc false
  # Every upstream basic-catalog example bundle and both JSONL
  # contact-form samples go through the FULL pipeline — payload sniffing,
  # preflight, per-version envelope validation with the real catalog,
  # and operation extraction — and then back out through the encoder.
  # This is the end-to-end wire-fidelity gate:
  #
  #   * each bundle validates against the vendored bundle schema
  #     (`sample.json`) with the same registry upstream `run_tests.py`
  #     binds;
  #   * decode(encode(decode(x))) == decode(x) for the whole bundle;
  #   * every message that decodes to a single operation encodes back to
  #     exactly the original wire map, up to the defaults decoding fills
  #     in (see `strip_decoded_defaults/2`).
  #
  # Generates no tests when the upstream checkout is absent; the
  # reference guard test makes that visible.

  use ExUnit.Case, async: true

  alias A2UICore.Message
  alias A2UICore.Schema
  alias A2UICore.Schema.Engine
  alias A2UICore.Schema.Source
  alias A2UICore.Test.Reference

  for {version, file} <- Reference.bundle_files() do
    @external_resource file

    describe "bundle #{Path.basename(file)} (#{version})" do
      @describetag :examples_corpus

      test "decodes" do
        assert {:ok, [_ | _]} =
                 Message.decode(bundle(unquote(file))["messages"],
                   catalog: catalog(unquote(version))
                 )
      end

      test "validates against the bundle schema (sample.json)" do
        version = unquote(version)
        schema = Source.document(version, "sample.json")

        assert :ok =
                 Schema.validate(bundle(unquote(file)), schema,
                   registry: bundle_registry(version),
                   root: schema
                 )
      end

      test "round-trips through the encoder" do
        version = unquote(version)
        messages = bundle(unquote(file))["messages"]
        assert_round_trip(messages, version)
      end
    end
  end

  for {version, file} <- Reference.jsonl_files() do
    @external_resource file

    @tag :examples_corpus
    test "decodes and round-trips JSONL #{Path.basename(file)} (#{version})" do
      version = unquote(version)

      messages =
        unquote(file)
        |> File.read!()
        |> String.split("\n", trim: true)
        |> Enum.map(&Jason.decode!/1)

      for message <- messages do
        assert {:ok, _ops} = Message.decode(message, catalog: catalog(version))
      end

      assert_round_trip(messages, version)
    end
  end

  defp assert_round_trip(messages, version) do
    opts = [catalog: catalog(version)]
    {:ok, ops} = Message.decode(messages, opts)

    reencoded = Enum.map(ops, &Message.encode(&1, version: wire_version(&1, messages)))
    assert {:ok, ^ops} = Message.decode(reencoded, opts)

    for message <- messages, {:ok, [op]} <- [Message.decode(message, opts)] do
      encoded = Message.encode(op, version: message["version"])

      assert Engine.json_equal?(strip_decoded_defaults(encoded, message), message),
             "re-encoded message differs:\n  original: #{inspect(message)}\n  encoded:  #{inspect(encoded)}"
    end
  end

  # Decoding canonicalizes optional fields to their protocol defaults
  # (an absent updateDataModel `path` is the root "/"); drop a default
  # from the re-encoded map when the original omitted it.
  defp strip_decoded_defaults(%{"updateDataModel" => payload} = encoded, original) do
    if Map.has_key?(original["updateDataModel"] || %{}, "path") or payload["path"] != "/" do
      encoded
    else
      Map.put(encoded, "updateDataModel", Map.delete(payload, "path"))
    end
  end

  defp strip_decoded_defaults(encoded, _original), do: encoded

  # All messages of one bundle share a wire version.
  defp wire_version(_op, [%{"version" => version} | _]), do: version

  defp bundle(file), do: file |> File.read!() |> Jason.decode!()

  defp catalog(version), do: Source.catalog(version, :basic)

  defp bundle_registry(version) do
    %{
      "common_types.json" => Source.document(version, :common_types),
      "catalog.json" => catalog(version),
      list_name(version) => Source.document(version, :list),
      envelope_name(version) => Source.document(version, :agent_to_renderer)
    }
  end

  defp list_name("v1.0"), do: "agent_to_renderer_list.json"
  defp list_name(_v0_9), do: "server_to_client_list.json"

  defp envelope_name("v1.0"), do: "agent_to_renderer.json"
  defp envelope_name(_v0_9), do: "server_to_client.json"
end

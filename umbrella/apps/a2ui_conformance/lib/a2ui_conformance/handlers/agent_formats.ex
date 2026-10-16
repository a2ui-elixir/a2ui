defmodule A2UIConformance.Handlers.AgentFormats do
  @moduledoc false

  # The inference-format actions of the agent harness
  # (python/a2ui_agent/tests/conformance/test_conformance.py), for the
  # direct JSON format:
  #
  #   * compile / decompile (`test_compiler_conformance`,
  #     `test_decompiler_conformance`; in multi_catalog_formats.yaml
  #     component lists compare sorted by id);
  #   * unwrap / wrap / parse_response (`test_response_parser_conformance`);
  #   * generate_prompt_snippet / create_format / create_processor
  #     (`run_format_case`, `run_create_processor_case`).

  @behaviour A2UIConformance.Handler

  import ExUnit.Assertions

  alias A2UIAgent.{DirectJson, Generator, RequestProcessor}
  alias A2UIAgent.DirectJson.Parser
  alias A2UIConformance.{AgentFixtures, Case, Matchers}

  @multi_catalog_suite "agent/multi_catalog_formats.yaml"

  @impl true
  def run(%Case{action: action} = test_case, _context) do
    run_action(action, test_case.raw, test_case.suite == @multi_catalog_suite)
    :ok
  end

  # -- compile and decompile ---------------------------------------------------------

  defp run_action("compile", raw, sorted?) do
    parser = make_parser!(raw["args"])

    case raw do
      %{"expect_error" => expected} ->
        AgentFixtures.expect_error(expected, fn -> Parser.compile(parser, raw["input"]) end)

      %{"expect" => expected} ->
        assert {:ok, compiled} = Parser.compile(parser, raw["input"])
        compiled = drop_present(compiled, raw["expect_present"] || [])
        assert_messages(expected, compiled, sorted?)
    end
  end

  defp run_action("decompile", raw, sorted?) do
    parser = make_parser!(raw["args"])
    messages = raw["messages"]
    notation = Parser.decompile(messages)
    expect_snippet(notation, raw["expect_contains"], raw["expect_absent"])

    if raw["expect_round_trip"] do
      assert {:ok, recompiled} = Parser.compile(parser, notation)
      assert_messages(messages, recompiled, sorted?)
    end

    if Map.has_key?(raw, "expect_recompiled") do
      assert {:ok, recompiled} = Parser.compile(parser, notation)
      assert_messages(raw["expect_recompiled"], recompiled, false)
    end
  end

  # -- response parsing --------------------------------------------------------------

  defp run_action("unwrap", raw, _sorted?) do
    assert_raw_parts(raw["expect"], Parser.unwrap(raw["input"]))
  end

  defp run_action("wrap", raw, _sorted?) do
    output = raw["parts"] |> Enum.map(&raw_part/1) |> Parser.wrap()

    if Map.has_key?(raw, "expect_output"), do: assert(output == raw["expect_output"])
    expect_snippet(output, raw["expect_contains"], nil)
    if raw["expect_round_trip"], do: assert_raw_parts(raw["parts"], Parser.unwrap(output))
  end

  defp run_action("parse_response", raw, _sorted?) do
    args = raw["args"]
    parser = make_parser!(args)

    parse = fn ->
      Parser.parse_response(parser, raw["input"], wrapped: Map.get(args, "wrapped", true))
    end

    case raw do
      %{"expect_error" => expected} ->
        AgentFixtures.expect_error(expected, parse)

      %{"expect" => expected} ->
        assert {:ok, parts} = parse.()

        Matchers.assert_json_equal(
          expected,
          Enum.map(parts, &AgentFixtures.part_to_map/1),
          "parts"
        )
    end
  end

  # Each step's chunk must yield exactly the step's parts (or the step's
  # error, which ends the case). With `expect_matches_single_shot`, a
  # fresh parser reading the whole response at once yields everything the
  # steps yielded.
  defp run_action("parse_chunk", raw, _sorted?) do
    args = raw["args"]
    wrapped = Map.get(args, "wrapped", true)

    result =
      Enum.reduce_while(raw["steps"], {make_parser!(args), [], []}, &chunk_step(&1, &2, wrapped))

    case result do
      {_parser, chunks, yielded} ->
        if raw["expect_matches_single_shot"],
          do: expect_single_shot(make_parser!(args), chunks, yielded, wrapped)

      :errored ->
        :ok
    end
  end

  # -- prompts, formats and processors -------------------------------------------------

  defp run_action("generate_prompt_snippet", raw, _sorted?) do
    case raw do
      %{"expect_error" => expected} ->
        AgentFixtures.expect_error(expected, fn ->
          prompt(raw["args"])
        end)

      _expect ->
        assert {:ok, format} = make_format(raw["args"])
        assert {:ok, snippet} = DirectJson.prompt(format)

        if file = raw["expect_file"],
          do:
            assert(
              snippet == File.read!(AgentFixtures.path(file)),
              "snippet differs from #{file}"
            )

        expect_snippet(snippet, raw["expect_contains"], raw["expect_absent"])
        if raw["expect_deterministic"], do: assert({:ok, ^snippet} = DirectJson.prompt(format))
    end
  end

  defp run_action("create_format", raw, _sorted?) do
    args = raw["args"]

    case raw do
      %{"expect_error" => expected} ->
        AgentFixtures.expect_error(expected, fn -> make_format(args) end)

      _expect ->
        expect = raw["expect"] || %{}
        assert {:ok, format} = make_format(args)

        if expect["parser_state_isolated"] do
          first = probe(DirectJson.parser(format), args["probe_chunks"])
          assert Enum.any?(first, &(&1 != []))
          assert probe(DirectJson.parser(format), args["probe_chunks"]) == first
        end

        assert {:ok, snippet} = DirectJson.prompt(format)

        expect_snippet(
          snippet,
          expect["prompt_snippet_contains"],
          expect["prompt_snippet_absent"]
        )
    end
  end

  defp run_action("create_processor", raw, _sorted?) do
    args = raw["args"]
    configs = Enum.map(args["catalogs"], &AgentFixtures.format_catalog_config/1)

    generator =
      Generator.new(configs,
        examples: AgentFixtures.examples(args),
        format: format_spec(args),
        accepts_inline_catalogs: args["accepts_inline_catalogs"] == true
      )

    create = fn ->
      with {:ok, processor} <-
             Generator.create_processor(generator, args["renderer_capabilities"]),
           {:ok, snippet} <- RequestProcessor.prompt(processor) do
        {:ok, {processor, snippet}}
      end
    end

    case raw do
      %{"expect_error" => expected} ->
        AgentFixtures.expect_error(expected, create)

      _expect ->
        assert {:ok, {processor, snippet}} = create.()
        expect_processor(processor, snippet, raw["expect"] || %{})
        if raw["then_parse"], do: then_parse(processor, raw["then_parse"])
    end
  end

  defp expect_processor(processor, snippet, expect) do
    active = RequestProcessor.active_catalogs(processor)

    if Map.has_key?(expect, "active_catalog_ids"),
      do: assert(Enum.map(active, & &1.catalog_id) == expect["active_catalog_ids"])

    active
    |> Enum.zip(expect["catalogs"] || [])
    |> Enum.each(fn {catalog, expected} -> AgentFixtures.expect_catalog(catalog, expected) end)

    expect_snippet(snippet, expect["prompt_snippet_contains"], expect["prompt_snippet_absent"])
  end

  defp then_parse(processor, %{"expect_error" => expected} = parse),
    do:
      AgentFixtures.expect_error(expected, fn ->
        RequestProcessor.parse_response(processor, parse["input"])
      end)

  defp then_parse(processor, parse) do
    assert {:ok, parts} = RequestProcessor.parse_response(processor, parse["input"])

    Matchers.assert_json_equal(
      parse["expect"],
      Enum.map(parts, &AgentFixtures.part_to_map/1),
      "parts"
    )
  end

  # -- helpers ---------------------------------------------------------------------------

  defp format_spec(args) do
    {DirectJson,
     allowed_messages: args["allowed_messages"], progressive_keys: args["progressive_keys"]}
  end

  defp make_parser!(args) do
    {:ok, parser} =
      Parser.new(AgentFixtures.catalogs_for(args), progressive_keys: args["progressive_keys"])

    parser
  end

  defp make_format(args) do
    catalogs =
      if Map.has_key?(args, "catalogs") or Map.has_key?(args, "catalog"),
        do: AgentFixtures.catalogs_for(args),
        else: []

    DirectJson.new(catalogs,
      examples: AgentFixtures.examples(args),
      allowed_messages: args["allowed_messages"],
      progressive_keys: args["progressive_keys"]
    )
  end

  defp probe(parser, chunks) do
    chunks
    |> Enum.map_reduce(parser, fn chunk, parser ->
      {:ok, parser, parts} = Parser.parse_chunk(parser, chunk)
      {Enum.map(parts, &AgentFixtures.part_to_map/1), parser}
    end)
    |> elem(0)
  end

  defp chunk_step(%{"expect_error" => expected} = step, {parser, _chunks, _yielded}, wrapped) do
    AgentFixtures.expect_error(expected, fn ->
      Parser.parse_chunk(parser, step["input"], wrapped: wrapped)
    end)

    {:halt, :errored}
  end

  defp chunk_step(%{"expect" => expected} = step, {parser, chunks, yielded}, wrapped) do
    assert {:ok, parser, parts} = Parser.parse_chunk(parser, step["input"], wrapped: wrapped)
    parts = Enum.map(parts, &AgentFixtures.part_to_map/1)
    Matchers.assert_json_equal(expected, parts, "parts of #{inspect(step["input"])}")
    {:cont, {parser, [step["input"] | chunks], yielded ++ parts}}
  end

  defp expect_single_shot(parser, chunks, yielded, wrapped) do
    response = chunks |> Enum.reverse() |> Enum.join()
    assert {:ok, parts} = Parser.parse_response(parser, response, wrapped: wrapped)

    Matchers.assert_json_equal(
      yielded,
      Enum.map(parts, &AgentFixtures.part_to_map/1),
      "single shot"
    )
  end

  defp prompt(args), do: with({:ok, format} <- make_format(args), do: DirectJson.prompt(format))

  defp expect_snippet(snippet, contains, absent) do
    for fragment <- contains || [],
        do: assert(String.contains?(snippet, fragment), "#{inspect(fragment)} not in snippet")

    for fragment <- absent || [],
        do:
          refute(
            String.contains?(snippet, fragment),
            "#{inspect(fragment)} unexpectedly in snippet"
          )
  end

  defp assert_messages(expected, actual, true),
    do: Matchers.assert_json_equal(sort_components(expected), sort_components(actual), "messages")

  defp assert_messages(expected, actual, false),
    do: Matchers.assert_json_equal(expected, actual, "messages")

  defp sort_components(messages), do: Enum.map(messages, &sort_message_components/1)

  defp sort_message_components(message) do
    Enum.reduce(["createSurface", "updateComponents"], message, fn key, message ->
      case message do
        %{^key => %{"components" => components} = body} when is_list(components) ->
          sorted = Enum.sort_by(components, &to_string(&1["id"]))
          Map.put(message, key, Map.put(body, "components", sorted))

        _other ->
          message
      end
    end)
  end

  # `expect_present` pointers must name a non-empty value; they are then
  # removed before the comparison.
  defp drop_present(compiled, pointers) do
    Enum.reduce(pointers, compiled, fn pointer, compiled ->
      tokens = pointer |> String.trim("/") |> String.split("/")
      assert get_in_pointer(compiled, tokens) not in [nil, ""], "#{pointer} is empty"
      delete_pointer(compiled, tokens)
    end)
  end

  defp get_in_pointer(value, []), do: value

  defp get_in_pointer(list, [token | rest]) when is_list(list),
    do: get_in_pointer(Enum.at(list, String.to_integer(token)), rest)

  defp get_in_pointer(map, [token | rest]) when is_map(map),
    do: get_in_pointer(Map.get(map, token), rest)

  defp get_in_pointer(_other, _tokens), do: nil

  defp delete_pointer(list, [token]) when is_list(list),
    do: List.delete_at(list, String.to_integer(token))

  defp delete_pointer(map, [token]) when is_map(map), do: Map.delete(map, token)

  defp delete_pointer(list, [token | rest]) when is_list(list),
    do: List.update_at(list, String.to_integer(token), &delete_pointer(&1, rest))

  defp delete_pointer(map, [token | rest]) when is_map(map),
    do: Map.update!(map, token, &delete_pointer(&1, rest))

  # Raw parts compare as the harness writes them: `{"text": ...}` or
  # `{"a2ui_raw": ...}`, plus `"is_final": false` for an unfinished block.
  defp assert_raw_parts(expected, actual) do
    expected =
      Enum.map(
        expected,
        &Map.reject(&1, fn {key, value} -> key == "is_final" and value == true end)
      )

    assert Enum.map(actual, &raw_part_to_map/1) == expected
  end

  defp raw_part_to_map({:text, text}), do: %{"text" => text}
  defp raw_part_to_map({:a2ui_raw, raw, true}), do: %{"a2ui_raw" => raw}
  defp raw_part_to_map({:a2ui_raw, raw, false}), do: %{"a2ui_raw" => raw, "is_final" => false}

  defp raw_part(%{"text" => text}), do: {:text, text}

  defp raw_part(%{"a2ui_raw" => raw} = part),
    do: {:a2ui_raw, raw, Map.get(part, "is_final", true)}
end

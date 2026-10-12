defmodule A2UIConformance.SuiteTest do
  @moduledoc false

  # Generated conformance tests: one ExUnit test per upstream YAML case,
  # dispatched through `A2UIConformance.Dispatcher`.
  #
  # Cases load at compile time; every suite file is registered with
  # `@external_resource` so suite edits trigger recompilation. Skip
  # decisions come from `A2UIConformance.SkipPolicy` and are derived per
  # case (the explicit list is validated, so skip entries cannot rot).

  use ExUnit.Case, async: false

  alias A2UIConformance.{Dispatcher, Registry, SkipPolicy}

  @load Registry.load_all()

  @case_list (case @load do
                {:ok, list} -> list
                {:error, _reason} -> []
              end)

  @suite_files (case @load do
                  {:ok, _list} ->
                    root = Registry.reference_root()
                    Registry.suite_files() |> Enum.map(&Path.join([root, "conformance", &1]))

                  {:error, _reason} ->
                    []
                end)

  for file <- @suite_files do
    @external_resource file
  end

  test "all conformance suites load" do
    # Mirrors the reference's `test_all_suites_load`: a missing checkout
    # or a suite parse failure fails here rather than dropping suites.
    assert @case_list != [],
           "conformance suites failed to load: #{inspect(@load)}"
  end

  test "explicit skip list has no stale entries" do
    assert :ok = SkipPolicy.validate_explicit_skips!(@case_list)
  end

  test "every case names a known action" do
    unknown =
      Enum.filter(@case_list, fn case ->
        match?(:unknown, Dispatcher.resolve(case.action || ""))
      end)

    assert unknown == [],
           "cases reference actions unknown to the dispatcher: " <>
             inspect(Enum.map(unknown, &{&1.suite, &1.name, &1.action}))
  end

  for case <- @case_list do
    @tag :conformance

    skip_reason =
      case SkipPolicy.skip_for(case) do
        {:skip, reason} -> reason
        nil -> nil
      end

    if skip_reason do
      @tag skip: skip_reason
    end

    test "#{case.suite} :: #{case.name}" do
      case = unquote(Macro.escape(case))

      assert {:ok, handler} = Dispatcher.resolve(case.action)
      :ok = handler.run(case, %{})
    end
  end
end

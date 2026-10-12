defmodule A2UICore.ReferenceGuardTest do
  @moduledoc false
  # The fidelity suites (spec cases, example corpus) generate their tests
  # from the upstream checkout and silently generate none when it is
  # missing. This guard makes a missing or mis-resolved checkout visible:
  # it fails under `A2UI_REQUIRE_REFERENCE=1` (CI), and whenever the
  # checkout is found, discovery must yield files.

  use ExUnit.Case, async: true

  alias A2UICore.Test.Reference

  test "the reference checkout is present when required" do
    if Reference.required?() do
      assert Reference.root(),
             "A2UI_REQUIRE_REFERENCE is set but reference/a2ui was not found " <>
               "(set A2UI_REFERENCE_ROOT or clone it, see README)"
    end
  end

  test "discovery finds the fidelity corpus whenever the checkout exists" do
    if Reference.root() do
      assert Reference.spec_case_files() != []
      assert Reference.bundle_files() != []
      assert length(Reference.jsonl_files()) == 2
    end
  end
end

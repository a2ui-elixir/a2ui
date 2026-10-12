defmodule A2UICore.Validation.ConfigTest do
  @moduledoc false
  use ExUnit.Case, async: true

  alias A2UICore.Validation.Config

  doctest A2UICore.Validation.Config

  test "strict is the default" do
    assert Config.new() == Config.strict()
    assert Config.strict().root_id == "root"
    assert Config.strict().max_depth == nil
  end

  test "relaxed tolerates orphans, dangling references, a missing root and unknown elements" do
    relaxed = Config.relaxed()

    assert relaxed.allow_orphan_components
    assert relaxed.allow_dangling_references
    assert relaxed.allow_missing_root
    assert relaxed.allow_unknown_elements
    assert relaxed.root_id == "root"
  end

  test "new overrides the strict preset" do
    config = Config.new(root_id: "main", max_depth: 3, allowed_messages: ["createSurface"])

    assert config.root_id == "main"
    assert config.max_depth == 3
    assert config.allowed_messages == ["createSurface"]
    refute config.allow_orphan_components
  end

  test "new rejects unknown options" do
    assert_raise KeyError, fn -> Config.new(bogus: true) end
  end
end

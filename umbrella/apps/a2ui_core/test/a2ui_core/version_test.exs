defmodule A2UICore.VersionTest do
  @moduledoc false
  use ExUnit.Case, async: true

  alias A2UICore.Version

  doctest A2UICore.Version

  describe "all/0 and supported/0" do
    test "all includes legacy and current" do
      assert Version.all() == ["v0.8", "v0.9", "v0.9.1", "v1.0"]
    end

    test "supported excludes v0.8" do
      assert Version.supported() == ["v0.9", "v0.9.1", "v1.0"]
    end
  end

  describe "protocol_version?/1" do
    test "accepts supported and legacy strings in any casing convention" do
      assert Version.protocol_version?("v0.9")
      assert Version.protocol_version?("v0.9.1")
      assert Version.protocol_version?("v1.0")
      assert Version.protocol_version?("v0.9.0")
      assert Version.protocol_version?("1.0.0-beta")
    end

    test "rejects unknown versions" do
      refute Version.protocol_version?("v0.10")
      refute Version.protocol_version?("v2.0")
      refute Version.protocol_version?("hello")
      refute Version.protocol_version?(nil)
    end
  end

  describe "to_protocol_version/1" do
    test "normalizes" do
      assert {:ok, "v0.9"} = Version.to_protocol_version("v0.9")
      assert {:ok, "v1.0"} = Version.to_protocol_version("v1.0")
      assert {:ok, "v1.0"} = Version.to_protocol_version("1.0.0-beta")
    end

    test "unknown version" do
      assert :error = Version.to_protocol_version("v0.10")
    end
  end

  describe "catalog_compatible?/2" do
    test "exact matches are compatible" do
      assert Version.catalog_compatible?("v1.0", "v1.0")
      assert Version.catalog_compatible?("v0.9", "v0.9")
    end

    test "explicit map: 0.9 <-> 0.9.1 symmetry" do
      assert Version.catalog_compatible?("v0.9", "v0.9.1")
      assert Version.catalog_compatible?("v0.9.1", "v0.9")
    end

    test "mismatched 0.x to 1.0 line is incompatible" do
      refute Version.catalog_compatible?("v1.0", "v0.9")
    end

    test "same-major rule applies for >= 1" do
      assert Version.catalog_compatible?("v1.1", "v1.0")
    end

    test "non-semver ids: normalization fallback" do
      assert Version.catalog_compatible?("custom", "custom")
      refute Version.catalog_compatible?("custom", "other")
    end
  end
end

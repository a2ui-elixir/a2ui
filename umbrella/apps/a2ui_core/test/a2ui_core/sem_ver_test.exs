defmodule A2UICore.SemVerTest do
  @moduledoc false
  use ExUnit.Case, async: true

  alias A2UICore.SemVer

  doctest A2UICore.SemVer

  describe "normalize/1" do
    test "strips a leading v or V" do
      assert SemVer.normalize("v1_0") == "1.0"
      assert SemVer.normalize("V1_0") == "1.0"
    end

    test "replaces underscores with dots in the release core only" do
      assert SemVer.normalize("v0_9_1") == "0.9.1"
      assert SemVer.normalize("1_0_0-dev_release") == "1.0.0-dev_release"
    end

    test "empty and non-binary inputs normalize to empty string" do
      assert SemVer.normalize(nil) == ""
      assert SemVer.normalize("") == ""
      assert SemVer.normalize(12) == ""
    end
  end

  describe "parse/1" do
    test "full SemVer (with pre-release and build)" do
      assert {:ok, %{major: 1, minor: 0, patch: 0, prerelease: ["beta"], build: ["abc"]}} =
               SemVer.parse("1.0.0-beta+abc")
    end

    test "v0.9 and variants parse to the same point release" do
      assert {:ok, %{major: 0, minor: 9, patch: 0}} = SemVer.parse("v0.9")
      assert {:ok, %{major: 0, minor: 9, patch: 0}} = SemVer.parse("0.9")
      assert {:ok, %{major: 0, minor: 9, patch: 0}} = SemVer.parse("v0.9.0")
    end

    test "v0.9.1 parses to a three-part version" do
      assert {:ok, %{major: 0, minor: 9, patch: 1}} = SemVer.parse("v0.9.1")
      assert {:ok, %{major: 0, minor: 9, patch: 1}} = SemVer.parse("0.9.1")
    end

    test "rejects non-semver strings" do
      assert :error = SemVer.parse("hello")
      assert :error = SemVer.parse("")
      assert :error = SemVer.parse(nil)
    end

    test "v1_0 underscore variant parses after normalization" do
      assert {:ok, %{major: 1, minor: 0, patch: 0}} = SemVer.parse(SemVer.normalize("v1_0"))
    end
  end

  describe "to_canonical/1" do
    test "zero patch collapses to major.minor" do
      assert SemVer.to_canonical("v0.9") == "0.9"
      assert SemVer.to_canonical("v1.0") == "1.0"
      assert SemVer.to_canonical("1.0.0") == "1.0"
    end

    test "non-zero patch prints all three components" do
      assert SemVer.to_canonical("v0.9.1") == "0.9.1"
    end

    test "prerelease and build survive the canonical form" do
      assert SemVer.to_canonical("1.0.0-beta") == "1.0.0-beta"
      assert SemVer.to_canonical("1.0.0-beta+build.5") == "1.0.0-beta+build.5"
    end

    test "unparseable input returns nil" do
      assert SemVer.to_canonical("hello") == nil
      assert SemVer.to_canonical(nil) == nil
    end
  end

  describe "compare/2" do
    test "version 11 example ordering from semver.org" do
      chain = [
        "1.0.0-alpha",
        "1.0.0-alpha.1",
        "1.0.0-alpha.beta",
        "1.0.0-beta",
        "1.0.0-beta.2",
        "1.0.0-beta.11",
        "1.0.0-rc.1",
        "1.0.0"
      ]

      for {a, b} <- Enum.zip(chain, tl(chain)) do
        assert SemVer.compare(a, b) < 0, "expected #{a} < #{b}"
        assert SemVer.compare(b, a) > 0, "expected #{b} > #{a}"
      end
    end

    test "build metadata ignored for precedence" do
      assert SemVer.compare("1.0.0+a", "1.0.0+b") == 0
    end

    test "nil and unparseable compare less than parseable" do
      assert SemVer.compare(nil, "1.0") == -1
      assert SemVer.compare("1.0", nil) == 1
      assert SemVer.compare(nil, nil) == 0
    end
  end

  describe "at_least/2" do
    test "comparison respects ordering" do
      assert SemVer.at_least("v1.0", "v0.9")
      refute SemVer.at_least("v0.9", "v1.0")
    end

    test "boundary: equal is enough" do
      assert SemVer.at_least("v1.0", "v1.0")
    end

    test "bad input is treated as not at-least" do
      refute SemVer.at_least(nil, "v1.0")
      refute SemVer.at_least("bogus", "v1.0")
    end
  end
end

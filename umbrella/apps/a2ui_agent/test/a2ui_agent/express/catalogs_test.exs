defmodule A2UIAgent.Express.CatalogsTest do
  @moduledoc false
  use ExUnit.Case, async: true

  import A2UIAgent.Test.Fixtures, only: [catalog: 2, catalog: 3]

  alias A2UIAgent.Express.Catalogs
  alias A2UICore.Error

  test "the catalogs must be usable together" do
    assert {:error, %Error{category: :catalog}} = Catalogs.new([])

    assert {:error, %Error{message: message}} =
             Catalogs.new([catalog("a", ["T"]), catalog("a", ["T"])])

    assert message =~ "Duplicate catalog ID"

    assert {:error, %Error{message: message}} =
             Catalogs.new([catalog("a", ["T"], "v0.9"), catalog("b", ["T"], "v0.9")])

    assert message =~ "Several catalogs need A2UI v1.0 or later, but the catalogs target v0.9."
  end

  test "lookups across the catalogs" do
    {:ok, catalogs} = Catalogs.new([catalog("a", ["T", "U"]), catalog("b", ["T"])])

    assert catalogs.version == "v1.0"
    assert Catalogs.helper(catalogs, "b").catalog_id == "b"
    assert Catalogs.helper(catalogs, "x") == nil
    assert Catalogs.first_helper(catalogs).catalog_id == "a"
    assert Catalogs.sole_catalog_id(catalogs) == nil
    assert Catalogs.defining(catalogs, :component, "T") == ["a", "b"]
    assert Catalogs.defining(catalogs, :component, "U") == ["a"]
    assert Catalogs.defining(catalogs, :function, "f") == []
    assert Catalogs.label(:function) == "Function"
    assert Catalogs.v1?("v1.0")
    refute Catalogs.v1?("v0.9.1")

    {:ok, single} = Catalogs.new([catalog("only", ["T"], "v0.9")], "v0.9.1")
    assert single.version == "v0.9.1"
    assert Catalogs.sole_catalog_id(single) == "only"
  end
end

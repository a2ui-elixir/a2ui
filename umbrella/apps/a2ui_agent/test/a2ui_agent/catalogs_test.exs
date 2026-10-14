defmodule A2UIAgent.CatalogsTest do
  @moduledoc false
  use ExUnit.Case, async: true

  import A2UIAgent.Test.Fixtures

  alias A2UIAgent.Catalogs
  alias A2UICore.Error

  test "check/1 wants distinct catalogs of one protocol version" do
    a = catalog("a", ["Text"])

    assert Catalogs.check([a]) == {:ok, [a]}
    assert Catalogs.check([basic_v09(), catalog("b", ["Text"], "v0.9.1")]) |> elem(0) == :ok

    assert {:error, %Error{category: :catalog, message: "At least one catalog must be provided."}} =
             Catalogs.check([])

    assert {:error, %Error{category: :catalog, message: "Duplicate catalog ID: 'a'."}} =
             Catalogs.check([a, a])

    assert {:error, %Error{category: :catalog, message: message}} =
             Catalogs.check([a, catalog("b", ["Text"], "v0.9")])

    assert message == ~s(The catalogs target incompatible protocol versions: ["v0.9", "v1.0"].)

    assert {:error, %Error{category: :catalog, message: "Expected a list of catalogs."}} =
             Catalogs.check(:none)
  end

  test "protocol_version/1 is the canonical version" do
    assert Catalogs.protocol_version(basic()) == "v1.0"
    assert Catalogs.protocol_version(basic_v09()) == "v0.9.1"
    assert Catalogs.protocol_version(%{basic() | protocol_version: "custom"}) == "custom"
  end
end

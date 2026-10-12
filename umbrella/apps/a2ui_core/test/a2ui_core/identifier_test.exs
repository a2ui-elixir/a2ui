defmodule A2UICore.IdentifierTest do
  @moduledoc false
  use ExUnit.Case, async: true

  alias A2UICore.Identifier

  describe "valid?/1 — accepted" do
    for good <- ~w|Text submit_form _internal UserProfileCard item_id_1 ßeta Component_ℓ| do
      test "accepts #{inspect(good)}" do
        assert Identifier.valid?(unquote(good))
      end
    end
  end

  describe "valid?/1 — rejected" do
    for bad <- ["1stItem", "submit-form", "user#name", "calc$val", "User Card", "Cordüroy™"] do
      test "rejects #{inspect(bad)}" do
        refute Identifier.valid?(unquote(bad))
      end
    end

    test "rejects empty string and non-binary" do
      refute Identifier.valid?("")
      refute Identifier.valid?(nil)
      refute Identifier.valid?(42)
    end

    test "rejects strings that start with a digit after the @ strip" do
      refute Identifier.valid?("@1stItem")
      assert Identifier.valid?("@index")
    end

    test "rejects double @@ prefix (only one @ stripped)" do
      refute Identifier.valid?("@@path")
    end
  end

  describe "assert_valid!/2" do
    test "returns :ok on valid" do
      assert Identifier.assert_valid!("Text") == :ok
    end

    test "raises A2UICore.Error category :catalog on invalid" do
      assert_raise A2UICore.Error, fn ->
        Identifier.assert_valid!("1stItem")
      end
    end

    test "context string appears in message" do
      error =
        try do
          Identifier.assert_valid!("1stItem", "component name")
          flunk("expected raise")
        rescue
          error in A2UICore.Error -> error
        end

      assert error.category == :catalog
      assert error.message =~ "component name"
      assert error.message =~ "1stItem"
    end
  end
end

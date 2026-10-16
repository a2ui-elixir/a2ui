defmodule A2UICore.IdentifierTest do
  @moduledoc false
  use ExUnit.Case, async: true

  alias A2UICore.Identifier

  describe "valid?/1 — accepted" do
    for good <- ~w|Text submit_form _internal UserProfileCard item_id_1 ßeta Component_ℓ ℘map a·b| do
      test "accepts #{inspect(good)}" do
        assert Identifier.valid?(unquote(good))
      end
    end
  end

  describe "valid?/1 — rejected" do
    for bad <- [
          "1stItem",
          "submit-form",
          "user#name",
          "calc$val",
          "User Card",
          "Cordüroy™",
          "·a",
          "゛a",
          "Text\n"
        ] do
      test "rejects #{inspect(bad)}" do
        refute Identifier.valid?(unquote(bad))
      end
    end

    test "rejects empty string and non-binary" do
      refute Identifier.valid?("")
      refute Identifier.valid?(nil)
      refute Identifier.valid?(42)
    end

    test "continue?/1 takes one character" do
      assert Identifier.continue?("·")
      refute Identifier.continue?(nil)
    end

    test "a leading @ is ignored only when allowed, and a digit may not follow it" do
      refute Identifier.valid?("@index")
      assert Identifier.valid?("@index", allow_leading_at: true)
      refute Identifier.valid?("@1stItem", allow_leading_at: true)
      refute Identifier.valid?("@", allow_leading_at: true)
    end

    test "rejects double @@ prefix (only one @ ignored)" do
      refute Identifier.valid?("@@path")
      refute Identifier.valid?("@@path", allow_leading_at: true)
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

defmodule A2UICore.Validation.ReservedKeysTest do
  @moduledoc false
  use ExUnit.Case, async: true

  alias A2UICore.Error
  alias A2UICore.Validation.ReservedKeys

  doctest A2UICore.Validation.ReservedKeys

  describe "directive_like?/1" do
    test "a single @ prefix" do
      assert ReservedKeys.directive_like?("@call")
      assert ReservedKeys.directive_like?("@anything")
      refute ReservedKeys.directive_like?("@@call")
      refute ReservedKeys.directive_like?("call")
      refute ReservedKeys.directive_like?("")
    end
  end

  describe "unescape/1" do
    test "removes one @ from an escaped key" do
      assert ReservedKeys.unescape("@@note") == "@note"
      assert ReservedKeys.unescape("@@@x") == "@@x"
      assert ReservedKeys.unescape("plain") == "plain"
      assert ReservedKeys.unescape("@call") == "@call"
    end
  end

  describe "check/2" do
    test "accepts the known directives and escaped keys" do
      assert ReservedKeys.check(["@call", "args"], "v1.0") == :ok
      assert ReservedKeys.check(["@path"], "v1.0") == :ok
      assert ReservedKeys.check(["@@note", "plain"], "v1.0") == :ok
    end

    test "rejects any other single-@ key" do
      assert {:error, %Error{category: :validation, code: "INVALID_RESERVED_KEY"} = error} =
               ReservedKeys.check(["b", "@note"], "v1.0")

      assert error.message =~ "Unrecognized reserved protocol directive '@note'"
      assert [%{code: "INVALID_RESERVED_KEY", path: ""}] = error.details
    end

    test "reports the first offender in sorted order" do
      assert {:error, %Error{message: message}} = ReservedKeys.check(["@zed", "@alpha"], "v1.0")
      assert message =~ "'@alpha'"
    end

    test "versions before v1.0 have no reserved keys" do
      assert ReservedKeys.check(["@note"], "v0.9") == :ok
      assert ReservedKeys.check(["@note"], nil) == :ok
    end
  end
end

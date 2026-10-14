defmodule A2UIAgent.PayloadValidatorTest do
  @moduledoc false
  use ExUnit.Case, async: true

  import A2UIAgent.Test.Fixtures

  alias A2UIAgent.PayloadValidator
  alias A2UICore.Error

  defp error!(result) do
    assert {:error, %Error{} = error} = result
    error
  end

  describe "a surface the payload creates" do
    test "is valid with valid components reachable from the root" do
      assert PayloadValidator.validate([basic()], surface()) == :ok
      assert PayloadValidator.validate([basic()], create()) == :ok
    end

    test "may name a child that a later message adds" do
      payload = [
        create(),
        update([%{"id" => "root", "component" => "Column", "children" => ["t"]}]),
        update([text("t", "Hi")])
      ]

      assert PayloadValidator.validate([basic()], payload) == :ok
    end

    test "needs every reference resolved, every component reachable and a root" do
      dangling = [
        create(),
        update([%{"id" => "root", "component" => "Column", "children" => ["x"]}])
      ]

      orphan = [create(), update([text("root", "a"), text("o", "b")])]
      rootless = [create(), update([text("a", "a")])]

      assert %Error{category: :integrity, message: "Dangling reference" <> _} =
               error!(PayloadValidator.validate([basic()], dangling))

      assert %Error{category: :integrity, message: message} =
               error!(PayloadValidator.validate([basic()], orphan))

      assert message =~ "not reachable from 'root'"

      assert %Error{category: :integrity, message: "Missing root component" <> _} =
               error!(PayloadValidator.validate([basic()], rootless))
    end

    test "errors of other kinds are reported as validation errors" do
      assert %Error{category: :validation, message: "Catalog not found: nope"} =
               error!(PayloadValidator.validate([basic()], [create("s1", "nope")]))

      two_actions = Map.put(create(), "deleteSurface", %{"surfaceId" => "s1"})

      assert %Error{category: :validation, code: "INVALID_ACTION"} =
               error!(PayloadValidator.validate([basic()], [two_actions]))
    end
  end

  describe "a surface the payload only updates" do
    test "may reference components outside the payload and lack a root" do
      payload = [update([%{"id" => "a", "component" => "Column", "children" => ["elsewhere"]}])]

      assert PayloadValidator.validate([basic()], payload) == :ok
      assert PayloadValidator.validate([basic()], delete("s9")) == :ok
    end

    test "is checked with every message the payload sends it" do
      payload = [
        update([%{"id" => "a", "component" => "Column", "children" => ["b"]}]),
        update([text("b", "B")]),
        update([%{"id" => "b", "component" => "Text"}])
      ]

      assert %Error{category: :validation} = error!(PayloadValidator.validate([basic()], payload))
      assert PayloadValidator.validate([basic()], Enum.take(payload, 2)) == :ok
    end

    test "a message that names no surface is checked on its own" do
      no_surface = %{"version" => "v1.0", "deleteSurface" => %{}}

      assert %Error{category: :validation} =
               error!(PayloadValidator.validate([basic()], [no_surface]))
    end

    test "still needs valid components" do
      assert %Error{category: :validation, message: message} =
               error!(
                 PayloadValidator.validate([basic()], [
                   update([%{"id" => "a", "component" => "Text"}])
                 ])
               )

      assert message =~ "'text' is a required property"
    end

    test "passes in any catalog that defines all of its components" do
      catalogs = [catalog("a", ["Text"]), catalog("b", ["Text", "Card"])]
      payload = [update([%{"id" => "c", "component" => "Card"}])]

      assert PayloadValidator.validate(catalogs, payload) == :ok
    end

    test "is checked only in the catalog an earlier payload created it with" do
      catalogs = [catalog("a", ["Text"]), catalog("b", ["Text", "Card"])]
      payload = [update([%{"id" => "c", "component" => "Card"}])]

      assert PayloadValidator.validate(catalogs, payload, surface_catalog_ids: %{"s1" => "b"}) ==
               :ok

      assert %Error{category: :validation, message: message} =
               error!(
                 PayloadValidator.validate(catalogs, payload, surface_catalog_ids: %{"s1" => "a"})
               )

      assert message =~ "Unrecognized component type 'Card'"

      assert %Error{
               message: "Surface 's1' uses catalog 'x', which isn't one of the active catalogs."
             } =
               error!(
                 PayloadValidator.validate(catalogs, payload, surface_catalog_ids: %{"s1" => "x"})
               )
    end

    test "is checked in the first catalog when none defines all of its components" do
      catalogs = [catalog("a", ["Text"]), catalog("b", ["Card"])]

      payload = [
        update([%{"id" => "t", "component" => "Text"}, %{"id" => "c", "component" => "Card"}])
      ]

      assert %Error{message: message} = error!(PayloadValidator.validate(catalogs, payload))
      assert message =~ "'Card' is not a component of catalog 'a'"
    end

    test "a component that names its own catalog does not choose the surface's" do
      catalogs = [catalog("a", ["Text"]), catalog("b", ["Text", "Card"])]
      payload = [update([%{"id" => "c", "component" => "Card", "catalogId" => "b"}])]

      assert PayloadValidator.validate(catalogs, payload) == :ok
    end

    test "fails with the first catalog's error when every candidate rejects it" do
      catalogs = [catalog("a", ["Card"]), catalog("b", ["Card"])]
      payload = [update([%{"id" => "c", "component" => "Card", "text" => 5}])]

      assert %Error{category: :validation, message: message} =
               error!(PayloadValidator.validate(catalogs, payload))

      assert message =~ "5 is not of type 'string'"
    end
  end

  describe "messages" do
    test "must be JSON objects" do
      assert %Error{message: "Message 1 is not a JSON object."} =
               error!(PayloadValidator.validate([basic()], [create(), 42]))
    end

    test "must state a version the catalogs accept" do
      assert %Error{message: "Message 0 states no version, which v1.0 messages require."} =
               error!(PayloadValidator.validate([basic()], [Map.delete(create(), "version")]))

      assert %Error{message: message} =
               error!(
                 PayloadValidator.validate([basic()], [Map.put(create(), "version", "v0.9")])
               )

      assert message ==
               ~s(Message 0 states version "v0.9", but the catalogs target v1.0, whose messages state "v1.0".)

      v09 = basic_v09()
      id = v09.catalog_id

      assert PayloadValidator.validate([v09], [
               create("s1", id, "v0.9"),
               update([text("root", "Hi")], "s1", "v0.9.1")
             ]) == :ok
    end

    test "must not carry an empty components list" do
      assert %Error{message: "Message 0 (updateComponents) has an empty 'components' list."} =
               error!(PayloadValidator.validate([basic()], [update([])]))

      inline = put_in(create(), ["createSurface", "components"], [])

      assert %Error{message: "Message 0 (createSurface) has an empty 'components' list."} =
               error!(PayloadValidator.validate([basic()], [inline]))
    end
  end

  test "the catalogs must exist and accept the same message versions" do
    assert %Error{
             category: :catalog,
             message: "Validating a payload requires at least one catalog."
           } =
             error!(PayloadValidator.validate([], surface()))

    assert %Error{category: :catalog, message: message} =
             error!(PayloadValidator.validate([basic(), basic_v09()], surface()))

    assert message =~ "targets v1.0 and"
    assert message =~ "targets v0.9.1."

    assert PayloadValidator.validate([catalog("a", ["Text"], "v0.9"), basic_v09()], []) == :ok
  end
end

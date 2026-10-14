defmodule A2UIPhoenix.InputsTest do
  @moduledoc false
  use ExUnit.Case, async: true

  doctest A2UIPhoenix.Inputs

  alias A2UICore.Resolution.{Binding, Node}
  alias A2UIPhoenix.Inputs

  @today ~D[2026-10-14]

  defp node_of(type, props \\ %{}),
    do: %Node{
      ref: 1,
      instance_id: "x",
      component_id: "x",
      type: type,
      state: :resolved,
      data_path: "/",
      props: props
    }

  test "a checkbox writes a boolean" do
    assert Inputs.decode(node_of("CheckBox"), "value", "true", @today) == {:write, "value", true}

    assert Inputs.decode(node_of("CheckBox"), "value", "false", @today) ==
             {:write, "value", false}
  end

  test "a choice picker writes a list, and filters locally" do
    picker = node_of("ChoicePicker")

    assert Inputs.decode(picker, "value", "b", @today) == {:write, "value", ["b"]}
    assert Inputs.decode(picker, "value", ["", "a", "b"], @today) == {:write, "value", ["a", "b"]}
    assert Inputs.decode(picker, "filter", "ap", @today) == {:ui, :filter, "ap"}
  end

  test "a slider writes numbers and ignores anything else" do
    slider = node_of("Slider")

    assert Inputs.decode(slider, "value", "4", @today) == {:write, "value", 4}
    assert Inputs.decode(slider, "value", "2.5", @today) == {:write, "value", 2.5}
    assert Inputs.decode(slider, "value", "lots", @today) == :ignore
  end

  test "a date-time input keeps the half that did not change" do
    both = fn value ->
      node_of("DateTimeInput", %{"enableTime" => true, "value" => %Binding{value: value}})
    end

    date_only = node_of("DateTimeInput", %{"value" => %Binding{value: "2026-01-01"}})

    time_only =
      node_of("DateTimeInput", %{
        "enableDate" => false,
        "enableTime" => true,
        "value" => %Binding{value: "07:00"}
      })

    assert Inputs.decode(both.("2026-01-01T07:30:00"), "date", "2026-02-02", @today) ==
             {:write, "value", "2026-02-02T07:30:00"}

    assert Inputs.decode(both.("07:30"), "date", "2026-02-02", @today) ==
             {:write, "value", "2026-02-02T07:30"}

    assert Inputs.decode(both.(nil), "date", "2026-02-02", @today) ==
             {:write, "value", "2026-02-02T00:00:00"}

    assert Inputs.decode(both.("2026-01-01T07:30:00"), "time", "09:15", @today) ==
             {:write, "value", "2026-01-01T09:15:00"}

    assert Inputs.decode(both.("2026-01-01"), "time", "09:15", @today) ==
             {:write, "value", "2026-01-01T09:15:00"}

    assert Inputs.decode(both.(""), "time", "09:15", @today) ==
             {:write, "value", "2026-10-14T09:15:00"}

    assert Inputs.decode(date_only, "date", "2026-03-03", @today) ==
             {:write, "value", "2026-03-03"}

    assert Inputs.decode(time_only, "time", "08:00", @today) == {:write, "value", "08:00"}
  end

  test "any other field is written as submitted" do
    assert Inputs.decode(node_of("TextField"), "value", "hi", @today) == {:write, "value", "hi"}
    assert Inputs.decode(node_of("Custom"), "rating", "4", @today) == {:write, "rating", "4"}
    assert Inputs.decode(node_of("Custom"), "rating", %{"x" => 1}, @today) == :ignore
  end

  test "chips toggle in a multiple selection and replace otherwise" do
    multi = fn value ->
      node_of("ChoicePicker", %{
        "variant" => "multipleSelection",
        "value" => %Binding{value: value}
      })
    end

    single = node_of("ChoicePicker", %{"value" => %Binding{value: "a"}})

    assert Inputs.toggle(multi.(["a"]), "b") == {:write, "value", ["a", "b"]}
    assert Inputs.toggle(multi.(["a", "b"]), "a") == {:write, "value", ["b"]}
    assert Inputs.toggle(multi.("a"), "a") == {:write, "value", []}
    assert Inputs.toggle(multi.(nil), "a") == {:write, "value", ["a"]}
    assert Inputs.toggle(single, "b") == {:write, "value", ["b"]}
  end

  test "date and time parts" do
    assert Inputs.date_part("2026-10-14") == "2026-10-14"
    assert Inputs.time_part("09:30:15") == "09:30"
    assert Inputs.time_part("2026-10-14") == ""
  end
end

defmodule A2UIPhoenix.Inputs do
  @moduledoc """
  How a form change on a surface becomes a write.

  An input of node `ref` is named `a2ui[ref][field]`
  (`A2UIPhoenix.Context.input_name/2`), where `field` is normally the
  property the input writes. `decode/4` turns the submitted string into
  the value the property holds — a boolean for a `CheckBox`, a list for a
  `ChoicePicker`, a number for a `Slider`, a combined date-time for a
  `DateTimeInput` — or into local UI state (a `ChoicePicker` filter). Any
  other component's field is written as the submitted string.
  """

  alias A2UICore.Resolution.Node
  alias A2UIPhoenix.Components

  @moduledoc since: "0.1.0"

  @type decoded :: {:write, String.t(), term()} | {:ui, atom(), term()} | :ignore

  @doc """
  Decodes the submitted `raw` value of `field` of `node`. `today` fills
  in the date when only the time of a date-and-time input is set.
  """
  @spec decode(Node.t(), String.t(), term(), Date.t()) :: decoded()
  def decode(%Node{type: "CheckBox"}, "value", raw, _today),
    do: {:write, "value", raw in [true, "true", "on"]}

  def decode(%Node{type: "ChoicePicker"}, "filter", raw, _today),
    do: {:ui, :filter, Components.text(raw)}

  def decode(%Node{type: "ChoicePicker"}, "value", raw, _today) when is_list(raw),
    do: {:write, "value", Enum.reject(raw, &(&1 == ""))}

  def decode(%Node{type: "ChoicePicker"}, "value", raw, _today) when is_binary(raw),
    do: {:write, "value", [raw]}

  def decode(%Node{type: "Slider"}, "value", raw, _today) when is_binary(raw) do
    case number(raw) do
      nil -> :ignore
      value -> {:write, "value", value}
    end
  end

  def decode(%Node{type: "DateTimeInput"} = node, field, raw, today)
      when field in ["date", "time"] and is_binary(raw),
      do: {:write, "value", date_time(Components.props(node), field, raw, today)}

  def decode(%Node{}, field, raw, _today) when is_binary(raw), do: {:write, field, raw}
  def decode(%Node{}, _field, _raw, _today), do: :ignore

  @doc """
  The new value of a `ChoicePicker` when the chip for `option` is
  clicked: toggled in a multiple selection, the only one otherwise.
  """
  @spec toggle(Node.t(), String.t()) :: {:write, String.t(), [String.t()]}
  def toggle(%Node{} = node, option) do
    props = Components.props(node)

    selected =
      case props["value"] do
        list when is_list(list) -> list
        value when is_binary(value) -> [value]
        _none -> []
      end

    value =
      cond do
        props["variant"] != "multipleSelection" -> [option]
        option in selected -> List.delete(selected, option)
        true -> selected ++ [option]
      end

    {:write, "value", value}
  end

  defp number(raw) do
    case Integer.parse(raw) do
      {integer, ""} ->
        integer

      _not_an_integer ->
        case Float.parse(raw) do
          {float, ""} -> float
          _not_a_number -> nil
        end
    end
  end

  # The reference renderer's rules: the half that did not change is kept
  # from the current value, else defaulted.
  defp date_time(props, "date", date, _today) do
    current = Components.text(props["value"])

    if props["enableTime"] == true do
      time =
        cond do
          String.contains?(current, "T") -> current |> String.split("T", parts: 2) |> List.last()
          String.contains?(current, ":") -> current
          true -> "00:00:00"
        end

      "#{date}T#{time}"
    else
      date
    end
  end

  defp date_time(props, "time", time, today) do
    current = Components.text(props["value"])

    if date_enabled?(props) do
      date =
        cond do
          String.contains?(current, "T") -> current |> String.split("T", parts: 2) |> hd()
          String.contains?(current, "-") -> current
          true -> Date.to_iso8601(today)
        end

      "#{date}T#{time}:00"
    else
      time
    end
  end

  @doc """
  Whether a `DateTimeInput` picks a date: `enableDate`, which defaults to
  true only when `enableTime` is not set (a time-only input picks no
  date), as the basic catalog's guide and the reference renderers have
  it.

      iex> A2UIPhoenix.Inputs.date_enabled?(%{"enableTime" => true})
      false
      iex> A2UIPhoenix.Inputs.date_enabled?(%{})
      true
  """
  @spec date_enabled?(map()) :: boolean()
  def date_enabled?(props) do
    case props["enableDate"] do
      nil -> props["enableTime"] != true
      enabled -> enabled == true
    end
  end

  @doc """
  The `YYYY-MM-DD` part of a date or date-time value (`""` when there is
  none).

      iex> A2UIPhoenix.Inputs.date_part("2026-10-14T09:30:00")
      "2026-10-14"
      iex> A2UIPhoenix.Inputs.date_part("09:30")
      ""
  """
  @spec date_part(String.t()) :: String.t()
  def date_part(value) when is_binary(value) do
    cond do
      String.contains?(value, "T") ->
        value |> String.split("T", parts: 2) |> hd() |> String.slice(0, 10)

      String.contains?(value, "-") ->
        String.slice(value, 0, 10)

      true ->
        ""
    end
  end

  @doc """
  The `HH:MM` part of a time or date-time value (`""` when there is none).

      iex> A2UIPhoenix.Inputs.time_part("2026-10-14T09:30:00")
      "09:30"
  """
  @spec time_part(String.t()) :: String.t()
  def time_part(value) when is_binary(value) do
    cond do
      String.contains?(value, "T") ->
        value |> String.split("T", parts: 2) |> List.last() |> String.slice(0, 5)

      String.contains?(value, ":") ->
        String.slice(value, 0, 5)

      true ->
        ""
    end
  end
end
